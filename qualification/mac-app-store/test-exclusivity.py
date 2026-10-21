#!/usr/bin/env python3
"""Contend across independent cwd values and all three simulated native phases.

Only the wrapper is exercised here. No StoreKit reset or transaction is issued.
"""
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

wrapper = Path(__file__).with_name('exclusive-storekit.py').resolve()
runner = wrapper.with_name('test.sh')
lock = Path('/private/tmp') / f'com.hemsoft.mac476.storekit-{os.getuid()}.lock'
environment = dict(os.environ)
environment.pop('MAC476_STOREKIT_LOCK_FD', None)
missing = subprocess.run(['/bin/bash', str(runner), '--exclusive-child'], env=environment, capture_output=True, text=True)
assert missing.returncode != 0 and 'MAC476_STOREKIT_LOCK_FD' in missing.stderr
# Even a real but unlocked lock-file descriptor is not authority to enter.
forged = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    environment['MAC476_STOREKIT_LOCK_FD'] = str(forged)
    rejected = subprocess.run(['/bin/bash', str(runner), '--exclusive-child'], env=environment,
                              pass_fds=(forged,), capture_output=True, text=True)
    assert rejected.returncode != 0 and ('Inherited lock did not exclude' in rejected.stderr
                                         or 'BlockingIOError' in rejected.stderr)
finally:
    os.close(forged)
print('PASS direct exclusive-child flag rejects missing and forged inherited FD before native actions')
with tempfile.TemporaryDirectory(prefix='mac476-lock-regression-') as directory:
    root = Path(directory)
    worker = root / 'worker.py'
    worker.write_text('''import pathlib, sys, time
root, identity = pathlib.Path(sys.argv[1]), sys.argv[2]
marker = root / 'marker'
state = root / 'storekit-state'
with (root / 'events').open('a', buffering=1) as events:
    for phase in ['ordinary', 'prepare', 'relaunch']:
        events.write(identity + ':' + phase + '\\n')
        if phase == 'ordinary':
            marker.write_text(identity)
            state.write_text(identity)
        assert marker.read_text() == identity
        assert state.read_text() == identity
        time.sleep(0.15)
    events.write(identity + ':done\\n')
''')
    def start(identity):
        cwd = root / identity
        cwd.mkdir()
        return subprocess.Popen([sys.executable, str(wrapper), sys.executable, str(worker), str(root), identity], cwd=cwd)
    first = start('A')
    deadline = time.monotonic() + 10
    while not (root / 'events').exists():
        if first.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('First lock holder failed to start')
        time.sleep(0.01)
    # A deliberately stale timestamp on the *held* lock must not allow B in.
    os.utime(lock, (1, 1))
    inode = lock.stat().st_ino
    second = start('B')
    assert first.wait(timeout=20) == 0
    assert second.wait(timeout=20) == 0
    assert (root / 'events').read_text().splitlines() == [
        f'{identity}:{phase}' for identity in ['A', 'B'] for phase in ['ordinary', 'prepare', 'relaunch', 'done']]
    assert lock.stat().st_ino == inode, 'Never unlink/recreate stale lock'
    # A leftover unlocked inode is reusable without deletion or stale recovery.
    third = start('C')
    assert third.wait(timeout=20) == 0
    assert lock.stat().st_ino == inode
    # Kill the wrapper while its shell and descendant retain the inherited FD.
    # D pauses until the test explicitly releases it, so E must remain excluded.
    survivor = root / 'survivor.sh'
    survivor.write_text("""#!/bin/bash
set -eu
python3 "$1" --check-held
echo ready > "$2/ready"
for ((wait_tick=0; wait_tick<1500; wait_tick++)); do
  [[ -e "$2/release" ]] && break
  sleep 0.02
done
[[ -e "$2/release" ]]
python3 "$1" --check-held
echo done > "$2/done"
""")
    holder = subprocess.Popen([sys.executable, str(wrapper), '/bin/bash', str(survivor), str(wrapper), str(root)])
    deadline = time.monotonic() + 10
    while not (root / 'ready').exists():
        if holder.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Survivor failed to start')
        time.sleep(0.01)
    try:
        holder.send_signal(signal.SIGKILL)
        assert holder.wait(timeout=10) == -signal.SIGKILL
        # Independent nonblocking acquisition proves exclusion without a timing
        # sample of whether a scheduled contender happened to run.
        probe = subprocess.run([sys.executable, '-c',
            'import fcntl,sys; f=open(sys.argv[1], "r+"); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)', str(lock)],
            capture_output=True, text=True)
        assert probe.returncode != 0 and 'BlockingIOError' in probe.stderr
    finally:
        # Release only this test's own child, even if a regression assertion fails.
        (root / 'release').touch()
        deadline = time.monotonic() + 10
        while not (root / 'done').exists():
            if time.monotonic() > deadline:
                raise RuntimeError('Inherited child lock failed after wrapper termination')
            time.sleep(0.01)
    final = start('E')
    assert final.wait(timeout=20) == 0
    print('PASS descendant shell retains exclusive lock after wrapper SIGKILL')
    print('PASS full-procedure contention preserves marker and StoreKit-state stand-ins across worktrees')
    print('PASS stale held lock cannot be bypassed; leftover inode reused without deletion')
