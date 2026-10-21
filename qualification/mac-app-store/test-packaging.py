#!/usr/bin/env python3
"""Exercise bundle cleanup with fake compilation/signing; no native tools run."""
from pathlib import Path
import os
import subprocess
import tempfile

SOURCE = Path(__file__).with_name('build.sh').read_text()


def exercise(source):
    with tempfile.TemporaryDirectory(prefix='mac476-package-') as directory:
        root = Path(directory)
        (root / 'build.sh').write_text(source)
        tools = root / 'tools'
        tools.mkdir()
        for name in ['xcrun', 'codesign']:
            tool = tools / name
            tool.write_text('#!/bin/sh\nexit 0\n')
            tool.chmod(0o700)
        for name in ['Info.plist', 'Qualification.storekit']:
            (root / name).write_text('fixture')
        bundle = root / 'build/CodexBar Qualification.app'
        stale = bundle / 'Contents/Resources/obsolete/nested.txt'
        stale.parent.mkdir(parents=True)
        stale.write_text('obsolete')
        evidence = root / 'build/historical-evidence/receipt.txt'
        evidence.parent.mkdir()
        evidence.write_text('retain')
        result = subprocess.run(['/bin/bash', str(root / 'build.sh')],
                                env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH']),
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr)
        if evidence.read_text() != 'retain':
            raise RuntimeError('Sibling evidence changed')
        if stale.exists():
            raise RuntimeError('Obsolete nested resource survived packaging')
        if not (bundle / 'Contents/Resources/Qualification.storekit').exists():
            raise RuntimeError('Current resource missing')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='mac476-package-symlink-') as directory:
        root = Path(directory)
        outside = root / 'retained'
        outside.mkdir()
        sentinel = outside / 'receipt.txt'
        sentinel.write_text('retain')
        (root / 'build').symlink_to(outside, target_is_directory=True)
        (root / 'build.sh').write_text(SOURCE)
        result = subprocess.run(['/bin/bash', str(root / 'build.sh')],
                                capture_output=True, text=True, timeout=20)
        if result.returncode == 0 or 'Refusing symlinked build directory' not in result.stderr:
            raise RuntimeError('Redirected build directory was not rejected')
        if sentinel.read_text() != 'retain':
            raise RuntimeError('Redirected evidence changed')
        print('PASS symlinked build directory rejected before packaging')
    exercise(SOURCE)
    print('PASS exact bundle recreated; nested contamination removed; sibling evidence retained')
    old = SOURCE.replace('rm -rf -- "$app"\n', '')
    try:
        exercise(old)
    except RuntimeError as error:
        if str(error) != 'Obsolete nested resource survived packaging':
            raise
        print(f'PASS old mkdir-only control rejected: {error}')
    else:
        raise RuntimeError('Old packaging unexpectedly passed')
