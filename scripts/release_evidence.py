"""Shared evidence checks for manual release phases and native coverage inputs."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'scripts/pro-release-phases.json'
TEST_ID = re.compile(r'^[A-Za-z][A-Za-z0-9_]*/[A-Za-z][A-Za-z0-9_]*/test[A-Za-z0-9_]+$')


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def now():
    return datetime.now(timezone.utc).isoformat()


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def digest(path):
    """Hash contents and relative names, including symlink destinations."""
    path = Path(path)
    if not path.exists():
        raise ValueError(f'Missing evidence: {path}')
    if path.is_file():
        hasher = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(chunk)
        return hasher.hexdigest()
    hasher = hashlib.sha256()
    files = sorted(p for p in path.rglob('*') if p.is_file() or p.is_symlink())
    if not files:
        raise ValueError(f'Empty evidence directory: {path}')
    for file in files:
        hasher.update(str(file.relative_to(path)).encode() + b'\0')
        hasher.update(('link:' + os.readlink(file) if file.is_symlink() else digest(file)).encode() + b'\0')
    return hasher.hexdigest()


def source_snapshot(require_clean=True):
    status = capture(['git', 'status', '--porcelain', '--untracked-files=normal'])
    if require_clean and status:
        raise ValueError('Commit source before native release validation; worktree is not clean')
    files = capture(['git', 'ls-files', '-z']).split('\0')
    hashes = {name: digest(ROOT / name) for name in files if name}
    return dict(revision=capture(['git', 'rev-parse', 'HEAD']), root=str(ROOT),
                status=status, files=hashes)


def toolchain():
    return dict(xcode=capture(['xcodebuild', '-version']), swift=capture(['xcrun', 'swift', '--version']),
                developer_dir=os.environ.get('DEVELOPER_DIR', ''),
                sdk=capture(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']),
                sdk_build=capture(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-build-version']),
                architecture=capture(['uname', '-m']), image=os.environ.get('ImageVersion', 'local'))


def require_pinned(tools, device=None):
    pin = read(ROOT / 'scripts/function-risk/policy.json')['tools']['xcode']
    if any(not tools.get(key) for key in ('xcode', 'swift', 'developer_dir', 'sdk', 'sdk_build', 'architecture', 'image')):
        raise ValueError('Incomplete producer toolchain evidence')
    if tools['xcode'] != pin or tools['sdk'] != '26.5':
        raise ValueError(f'Qualification requires {pin!r} and iOS SDK 26.5; found {tools}')
    if device and (device['osVersion'] != '26.5' or device['osBuildNumber'] != '23F77'):
        raise ValueError(f'Qualification requires iOS Simulator 26.5 / 23F77: {device}')


def load_manifest(path=MANIFEST):
    manifest = read(path)
    if manifest.get('schema') != 1:
        raise ValueError('Unsupported phase manifest schema')
    schedules = {
        'ui_journeys': ['ui-original', 'ui-supplemental', 'ui-synthetic', 'ui-native', 'ui-native-purchase-error'],
        'ui_phases': ['ui-supplemental', 'ui-synthetic', 'ui-preparation', 'ui-native',
                      'ui-error-preparation', 'ui-native-purchase-error'],
        'native_phases': ['native-preparation', 'native-commerce', 'native-germany-preparation', 'native-germany'],
        'coverage_phases': ['ios', 'native-preparation', 'native-commerce', 'native-germany-preparation', 'native-germany'],
    }
    for key, expected in schedules.items():
        if manifest.get(key) != expected:
            raise ValueError(f'Missing, duplicate or reordered execution phases: {key}')
    if manifest.get('ui_cleanup') != 'ui-reset':
        raise ValueError('The normal StoreKit reset is mandatory')
    for name, phase in manifest['phases'].items():
        tests = phase['tests']
        if not tests or len(set(tests)) != len(tests) or len(tests) != phase['count']:
            raise ValueError(f'Empty, duplicate or inconsistent selectors: {name}')
        if not all(TEST_ID.fullmatch(test) for test in tests):
            raise ValueError(f'Only exact target/class/method selectors are allowed: {name}')
    journeys = [test for name in manifest['ui_journeys'] for test in manifest['phases'][name]['tests']]
    if len(journeys) != 51 or len(set(journeys)) != 51:
        raise ValueError('The UI partition must contain exactly 51 distinct user journeys')
    if set(journeys) & set(manifest['excluded_marketing']):
        raise ValueError('Marketing capture cannot be part of release journeys')
    if [manifest['phases'][name]['count'] for name in manifest['ui_journeys']] != [29, 6, 14, 1, 1]:
        raise ValueError('UI journey partition changed; reconcile the release contract')
    if [manifest['phases'][name]['count'] for name in manifest['native_phases']] != [1, 25, 1, 1]:
        raise ValueError('Native phase partition changed; reconcile the release contract')
    return manifest


def unique_tests(tests):
    if not tests or len(set(tests)) != len(tests) or not all(TEST_ID.fullmatch(test) for test in tests):
        raise ValueError('Empty, duplicate or malformed test identities')
    return sorted(tests)


def result_cases(tree):
    cases = []

    def walk(node, target=None):
        kind = node.get('nodeType')
        if kind in ('Repetition', 'Test Case Run'):
            raise ValueError('Repeated/retried test execution cannot qualify a phase')
        if kind in ('Unit test bundle', 'UI test bundle'):
            target = node['name'].removesuffix('.xctest')
        if kind == 'Test Case':
            local_id = node['nodeIdentifier'].removesuffix('()')
            url = urlparse(node['nodeIdentifierURL'])
            parts = unquote(url.path).strip('/').split('/')
            if url.scheme != 'test' or url.netloc != 'com.apple.xcode' or len(parts) != 4:
                raise ValueError(f'Unrecognized test identifier URL: {node}')
            identity = '/'.join(parts[1:])
            if parts[1] != target or '/'.join(parts[2:]) != local_id:
                raise ValueError(f'Test identity and bundle disagree: {node}')
            cases.append((identity, node.get('result')))
        for child in node.get('children', []):
            walk(child, target)

    for node in tree['testNodes']:
        walk(node)
    unique_tests([identity for identity, _ in cases])
    return cases


def validate_device(actual, expected):
    for key in ('deviceId', 'modelName', 'osVersion', 'osBuildNumber', 'architecture', 'platform'):
        if not actual.get(key) or actual[key] != expected[key]:
            raise ValueError(f'Result device mismatch for {key}: {actual.get(key)!r} != {expected[key]!r}')
    family = expected.get('family')
    prefix = {'iphone': 'iPhone', 'ipad': 'iPad'}.get(family)
    if prefix and not actual['modelName'].startswith(prefix):
        raise ValueError(f'Wrong device family: {actual}')


def validate_results(summary, tree, expected=None, device=None, started=None, ended=None):
    cases = result_cases(tree)
    actual = [identity for identity, _ in cases]
    expected = unique_tests(expected if expected is not None else actual)
    if Counter(actual) != Counter(expected):
        raise ValueError(f'Test identity mismatch; missing={sorted(set(expected)-set(actual))}; '
                         f'extra={sorted(set(actual)-set(expected))}')
    if any(status != 'Passed' for _, status in cases):
        raise ValueError(f'Nonpassing tests: {[case for case in cases if case[1] != "Passed"]}')
    counts = dict(totalTestCount=len(expected), passedTests=len(expected), failedTests=0,
                  skippedTests=0, expectedFailures=0)
    if summary.get('result') != 'Passed' or summary.get('testFailures'):
        raise ValueError('Test summary is not a clean pass')
    for key, value in counts.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            raise ValueError(f'Invalid test summary {key}: {summary.get(key)!r}, expected {value}')
    configurations = summary['devicesAndConfigurations']
    if not isinstance(configurations, list) or len(configurations) != 1 or len(tree['devices']) != 1:
        raise ValueError('Expected one test configuration on one device')
    result_device = configurations[0]['device']
    validate_device(tree['devices'][0], result_device)
    if device:
        validate_device(result_device, device)
    for key in ('passedTests', 'failedTests', 'skippedTests', 'expectedFailures'):
        if configurations[0].get(key) != counts[key]:
            raise ValueError(f'Device/configuration test counts disagree: {key}')
    if not summary.get('startTime') or summary.get('finishTime', 0) < summary['startTime']:
        raise ValueError('Missing or invalid test timestamps')
    if started and summary['startTime'] < datetime.fromisoformat(started).timestamp() - 2:
        raise ValueError('Result predates this phase')
    if ended and summary['finishTime'] > datetime.fromisoformat(ended).timestamp() + 2:
        raise ValueError('Result ends after this phase')
    return expected


def validate_receipt(receipt, snapshot, tools, expected, phase, result):
    if receipt.get('schema') != 1 or receipt.get('phase') != phase or receipt.get('exit') != 0:
        raise ValueError(f'Failed or incorrect phase receipt: {phase}')
    if receipt.get('source') != snapshot or snapshot['status']:
        raise ValueError(f'Stale, dirty or different source snapshot: {phase}')
    if receipt.get('tools') != tools:
        raise ValueError(f'Toolchain provenance mismatch: {phase}')
    if receipt.get('configuration') != 'Debug' or receipt.get('platform') != 'ios':
        raise ValueError(f'Wrong platform/configuration: {phase}')
    if receipt.get('expectedTests') != sorted(expected) or receipt.get('executedTests') != sorted(expected):
        raise ValueError(f'Incorrect expected/executed test provenance: {phase}')
    if Path(receipt.get('result', '')).resolve() != result.resolve() or receipt.get('result_sha256') != digest(result):
        raise ValueError(f'Result path or digest mismatch: {phase}')
    if not receipt.get('command') or not receipt.get('buildReceipt') or not receipt.get('discovery'):
        raise ValueError(f'Missing build/discovery/command provenance: {phase}')
    build_path = Path(receipt['buildReceipt'])
    if receipt.get('build_sha256') != digest(build_path):
        raise ValueError(f'Build receipt changed: {phase}')
    build = read(build_path)
    if build.get('source') != snapshot or build.get('tools') != tools or build.get('exit') != 0:
        raise ValueError(f'Build provenance mismatch: {phase}')
    if not build.get('binaries') or build.get('configuration') != 'Debug' or build.get('coverage') is not True:
        raise ValueError(f'Missing binary inventory: {phase}')
    if receipt.get('discovery_sha256') != digest(receipt['discovery']):
        raise ValueError(f'Discovery changed: {phase}')
    if discovery_tests(read(receipt['discovery'])) != sorted(expected):
        raise ValueError(f'Discovery identities changed: {phase}')
    if datetime.fromisoformat(build['ended']) > datetime.fromisoformat(receipt['started']):
        raise ValueError(f'Build was not completed before execution: {phase}')
    phase_config = load_manifest()['phases'].get(phase)
    scheme = phase_config['scheme'] if phase_config else 'CodexBarIOS'
    native = scheme == 'CodexBarProNativeCommerce'
    if build.get('scheme') != scheme or build.get('native') is not native:
        raise ValueError(f'Wrong scheme/native build: {phase}')
    validate_device(build['device'], receipt['device'])
    for command in (build['command'], receipt['command'], receipt['discoveryCommand']):
        for option, value in [('-scheme', scheme), ('-configuration', 'Debug'),
                              ('-enableCodeCoverage', 'YES'), ('-parallel-testing-enabled', 'NO'),
                              ('-maximum-concurrent-test-simulator-destinations', '1'),
                              ('-derivedDataPath', build['derivedData']),
                              ('-destination', f'platform=iOS Simulator,id={receipt["device"]["deviceId"]}')]:
            if command.count(option) != 1 or command[command.index(option) + 1] != value:
                raise ValueError(f'Build/execution command mismatch for {option}: {phase}')
        if any('retry' in argument or argument == '-test-iterations' for argument in command):
            raise ValueError(f'Repeated/retried phase command: {phase}')
        if any(argument.startswith('-skip-testing') for argument in command):
            raise ValueError(f'Skipped phase command: {phase}')
        if phase == 'ios' and any(argument.startswith('-only-testing') for argument in command):
            raise ValueError('Ordinary iOS build, discovery and execution must be unfiltered')
        if native and not all(flag in command for flag in ('CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-')):
            raise ValueError(f'Unsigned native command: {phase}')
    if build['command'][-1] != 'build-for-testing' or receipt['command'][-1] != 'test-without-building':
        raise ValueError(f'Build and test must be separate recorded invocations: {phase}')
    command = receipt['command']
    if command.count('-resultBundlePath') != 1 or Path(command[command.index('-resultBundlePath')+1]).resolve() != result.resolve():
        raise ValueError(f'Execution result path differs from receipt: {phase}')
    selected = sorted(argument.removeprefix('-only-testing:') for argument in receipt['command']
                      if argument.startswith('-only-testing:'))
    if phase_config and selected != sorted(expected):
        raise ValueError(f'Execution selectors differ from manifest: {phase}')
    discovery = receipt['discoveryCommand']
    if '-enumerate-tests' not in discovery or 'test-without-building' not in discovery:
        raise ValueError(f'Missing built-test discovery command: {phase}')
    if discovery.count('-test-enumeration-output-path') != 1 or Path(discovery[discovery.index('-test-enumeration-output-path') + 1]).resolve() != Path(receipt['discovery']).resolve():
        raise ValueError(f'Discovery output differs from receipt: {phase}')
    if sorted(argument for argument in discovery if argument.startswith('-only-testing:')) != sorted(
            argument for argument in receipt['command'] if argument.startswith('-only-testing:')):
        raise ValueError(f'Discovery and execution selectors differ: {phase}')
    if native and not build.get('adhocSigned'):
        raise ValueError(f'Unsigned native host: {phase}')


def discovery_tests(value):
    """Parse xcodebuild's flat JSON enumeration; reject unknown/empty schemas."""
    if value.get('errors') != [] or not isinstance(value.get('values'), list) or len(value['values']) != 1:
        raise ValueError('Expected one error-free flat test enumeration')
    plan = value['values'][0]
    if not isinstance(plan, dict) or not plan.get('testPlan'):
        raise ValueError('Missing enumerated test plan')
    groups = []
    for key in ('enabledTests', 'disabledTests'):
        rows = plan.get(key)
        if not isinstance(rows, list) or any(not isinstance(row, dict) or not isinstance(row.get('identifier'), str) for row in rows):
            raise ValueError(f'Invalid flat enumeration {key}')
        identities = [row['identifier'].removesuffix('()') for row in rows]
        groups.append(unique_tests(identities) if identities else [])
    if set(groups[0]) & set(groups[1]):
        raise ValueError('Enumeration both enables and disables the same test')
    return unique_tests(groups[0])
