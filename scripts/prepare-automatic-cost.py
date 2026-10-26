#!/usr/bin/env python3
"""Prepare one manual cost control; normal PR CI never calls this script."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


MANUAL_GUARD = """      - name: Verify manual automatic-cost identity
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.ui_validation_mode == 'automatic-cost' }}
        env:
          AUTOMATIC_COST_MODE: ${{ inputs.ui_validation_mode }}
          AUTOMATIC_COST_ROLE: ${{ inputs.cost_source_role }}
          AUTOMATIC_COST_BASE: ${{ inputs.comparison_base_sha }}
          AUTOMATIC_COST_IMAGE: ${{ inputs.cost_expected_image }}
          AUTOMATIC_COST_TOOLCHAIN: ${{ inputs.cost_expected_toolchain }}
        run: python3 scripts/prepare-automatic-cost.py --receipt "$RUNNER_TEMP/automatic-cost.json"

"""

class Refused(ValueError):
    pass


def command(*args):
    result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=10)
    if len(result.stdout.encode()) > 1_048_576:
        raise Refused('command-output-cap')
    return result.stdout.strip()


def automatic_job(workflow):
    match = re.search(r'^  swiftlint:\n.*?(?=^  [\w-]+:\n|\Z)', workflow, re.M | re.S)
    if not match:
        raise Refused('missing-automatic-job')
    block = match.group()
    # These two declarations affect only the explicit manual comparison mode.
    block = re.sub(
        r"^          fetch-depth: \$\{\{ inputs.ui_validation_mode == 'automatic-cost' && '0' \|\| '1' \}\}\n",
        '', block, flags=re.M,
    )
    block = block.replace(MANUAL_GUARD, '', 1)
    return block


def prepare(env, receipt):
    if (env.get('GITHUB_ACTIONS') != 'true'
            or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or env.get('GITHUB_REPOSITORY') != 'hemsoft-dev/codexbar-ios'
            or env.get('AUTOMATIC_COST_MODE') != 'automatic-cost'):
        raise Refused('wrong-context')
    candidate = env.get('GITHUB_SHA', '')
    baseline = env.get('AUTOMATIC_COST_BASE', '')
    role = env.get('AUTOMATIC_COST_ROLE')
    if not all(re.fullmatch(r'[0-9a-f]{40}', x) for x in (candidate, baseline)):
        raise Refused('invalid-source-sha')
    if candidate == baseline or role not in ('baseline', 'candidate'):
        raise Refused('invalid-source-role')
    image = env.get('ImageVersion', '')
    if not re.fullmatch(r'\d{8}\.\d{4}\.\d+', image) or image != env.get('AUTOMATIC_COST_IMAGE'):
        raise Refused('image-mismatch')
    if not env.get('ImageOS', '').startswith('macos26'):
        raise Refused('wrong-runner-os')
    developer = env.get('DEVELOPER_DIR', '')
    if developer != '/Applications/Xcode.app/Contents/Developer':
        raise Refused('different-automatic-toolchain-path')
    root = Path(command('git', 'rev-parse', '--show-toplevel')).resolve()
    if root != Path.cwd().resolve() or command('git', 'rev-parse', 'HEAD') != candidate:
        raise Refused('wrong-checkout')
    if command('git', 'status', '--porcelain'):
        raise Refused('dirty-checkout')
    command('git', 'merge-base', '--is-ancestor', baseline, candidate)
    if receipt.resolve().parent != Path(env.get('RUNNER_TEMP', '/nonexistent')).resolve():
        raise Refused('receipt-outside-runner-temp')
    workflow = '.github/workflows/ci.yml'
    before = automatic_job(command('git', 'show', f'{baseline}:{workflow}') + '\n')
    after = automatic_job(command('git', 'show', f'{candidate}:{workflow}') + '\n')
    if before != after:
        raise Refused('automatic-workload-changed')
    tools = {
        'developerDirectory': developer,
        'resolvedDeveloperDirectory': str(Path(developer).resolve()),
        'xcodeBuild': command('xcodebuild', '-version'),
        'swiftVersion': command('xcrun', 'swift', '--version'),
        'osVersion': command('sw_vers', '-productVersion'),
        'osBuild': command('sw_vers', '-buildVersion'),
        'architecture': command('uname', '-m'),
        'cpuCount': command('sysctl', '-n', 'hw.ncpu'),
        'memoryBytes': command('sysctl', '-n', 'hw.memsize'),
    }
    if any(len(value) > 4096 for value in tools.values()):
        raise Refused('toolchain-output-cap')
    fingerprint = hashlib.sha256(json.dumps(tools, sort_keys=True).encode()).hexdigest()
    expected = env.get('AUTOMATIC_COST_TOOLCHAIN', '')
    if role == 'candidate' and not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise Refused('missing-baseline-toolchain')
    if expected and expected != fingerprint:
        raise Refused('toolchain-mismatch')
    source = baseline if role == 'baseline' else candidate
    command('git', 'checkout', '--detach', source)
    if command('git', 'rev-parse', 'HEAD') != source or command('git', 'status', '--porcelain'):
        raise Refused('source-switch-unverified')
    result = {
        'schema': 1, 'role': role, 'baseline': baseline, 'candidate': candidate,
        'measuredSource': source, 'imageVersion': image, 'imageOS': env['ImageOS'],
        'toolchain': tools, 'toolchainSHA256': fingerprint,
        'automaticJobSHA256': hashlib.sha256(before.encode()).hexdigest(),
        'measurement': 'Complete Actions run elapsed and summed non-skipped job runtime; no deductions',
    }
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print('AUTOMATIC_COST_IDENTITY=' + json.dumps(result, sort_keys=True))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(os.environ, args.receipt)
    except Refused as error:
        print('AUTOMATIC_COST_REFUSED=' + str(error))
        return 1
    except (OSError, subprocess.SubprocessError):
        print('AUTOMATIC_COST_REFUSED=operational-or-command-failure')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
