#!/usr/bin/env python3
"""Hold a persistent, per-user machine-wide inode lock for the complete command.

Never unlink or steal a lock, including after a crash. The kernel releases flock
when the owning process exits. A separate worktree uses exactly the same path.
"""
import fcntl
import os
from pathlib import Path
import stat
import subprocess
import sys


def run(command):
    path = Path('/private/tmp') / f'com.hemsoft.mac476.storekit-{os.getuid()}.lock'
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise RuntimeError('Refusing unsafe StoreKit lock inode')
        print(f'Waiting for machine-wide StoreKit lock: {path}', flush=True)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        # If somebody unlinked/replaced the inode while we waited, never enter.
        if path.stat().st_ino != info.st_ino:
            raise RuntimeError('StoreKit lock inode changed; refusing unsafe execution')
        print('Acquired machine-wide StoreKit lock for complete procedure', flush=True)
        # The child inherits ownership too, so killing this wrapper cannot release
        # exclusivity while its xcodebuild or shell is still running.
        environment = os.environ | {'MAC476_STOREKIT_LOCK_FD': str(descriptor)}
        return subprocess.call(command, pass_fds=(descriptor,), env=environment)
    finally:
        os.close(descriptor)


def check_held():
    descriptor = int(os.environ['MAC476_STOREKIT_LOCK_FD'])
    path = Path('/private/tmp') / f'com.hemsoft.mac476.storekit-{os.getuid()}.lock'
    info = os.fstat(descriptor)
    if info.st_ino != path.stat().st_ino or info.st_uid != os.getuid():
        raise RuntimeError('Missing inherited StoreKit lock')
    # First require an already-held lock. Never acquire an unlocked forged FD.
    probe = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Only the original open-file description can reacquire this held
            # flock. A forged FD to the same inode fails while another owner runs.
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        raise RuntimeError('Inherited lock did not exclude an independent opener')
    finally:
        os.close(probe)


if __name__ == '__main__':
    if sys.argv[1:] == ['--check-held']:
        check_held()
    else:
        sys.exit(run(sys.argv[1:]))
