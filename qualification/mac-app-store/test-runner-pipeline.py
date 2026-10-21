#!/usr/bin/env python3
"""Run the actual shell with isolated fake tools. No real StoreKit is used."""
import os
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).with_name('test.sh')


def exercise(source, xcode_status, tee_status, metadata_status, expected, phases):
    with tempfile.TemporaryDirectory(prefix='mac476-pipeline-no-storekit-') as directory:
        root = Path(directory)
        runner = root / 'test.sh'
        runner.write_text(source)
        # Bypass only the native lock implementation in this isolated copy.
        # The phase loop and its actual xcodebuild | tee pipeline are unchanged.
        (root / 'exclusive-storekit.py').write_text('')
        tools = root / 'tools'
        tools.mkdir()
        xcode = tools / 'xcodebuild'
        xcode.write_text('''#!/bin/bash
if [[ "$1" == -version ]]; then
  printf 'Xcode fake\nBuild version CONTROL\n'
  exit 0
fi
echo phase >> "$CONTROL_ROOT/phases"
echo controlled-output
exit "$CONTROL_XCODE_STATUS"
''')
        tee = tools / 'tee'
        tee.write_text('''#!/bin/bash
/bin/cat >/dev/null
if [[ "$1" == -a ]]; then exit "$CONTROL_METADATA_STATUS"; fi
if [[ "$1" == *.log ]]; then exit "$CONTROL_TEE_STATUS"; fi
exit 0
''')
        for executable in [xcode, tee]:
            executable.chmod(0o700)
        # Supply harmless manifest inputs so the real provenance stage succeeds.
        for name in ['generate-project.py', 'Restore.swift', 'StoreKitTests.swift',
                     'StoreKitTestHost.swift', 'StoreKitTestHost.entitlements',
                     'Qualification.storekit', 'MacQualification.xcodeproj/project.pbxproj',
                     'MacQualification.xcodeproj/xcshareddata/xcschemes/MacQualification.xcscheme']:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                           DEVELOPER_DIR=str(tools), CONTROL_ROOT=str(root),
                           CONTROL_XCODE_STATUS=str(xcode_status), CONTROL_TEE_STATUS=str(tee_status),
                           CONTROL_METADATA_STATUS=str(metadata_status))
        result = subprocess.run(['/bin/bash', str(runner), '--exclusive-child'],
                                env=environment, capture_output=True, text=True, timeout=20)
        count = len((root / 'phases').read_text().splitlines())
        assert result.returncode == expected, (result.returncode, expected, result.stderr)
        assert count == phases, (count, phases)
        if tee_status:
            assert f'tee exit status {tee_status}' in result.stderr
        if metadata_status:
            assert 'Final metadata write failed' in result.stderr
        print(f'PASS Xcode={xcode_status} tee={tee_status} metadata={metadata_status}: exit={expected}, phases={phases}')


if __name__ == '__main__':
    source = SOURCE.read_text()
    for case in [(0, 74, 0, 74, 1), (65, 74, 0, 65, 1), (0, 0, 0, 0, 3),
                 (65, 0, 73, 65, 1), (0, 0, 73, 73, 3)]:
        exercise(source, *case)
    old = subprocess.check_output(['git', 'show',
        'e2c99d266fd55b721173856aabbef4878361a6c8:qualification/mac-app-store/test.sh'], text=True)
    try:
        exercise(old, 0, 74, 0, 74, 1)
    except AssertionError as error:
        print(f'PASS old-source control rejected: {error}')
    else:
        raise AssertionError('Old source unexpectedly passed logging-failure regression')
