#!/usr/bin/env python3
"""Build and capture committed simulator assets without inherited credentials.

Uses only task-owned devices supplied by the caller. It never creates, erases,
shuts down, deletes or chooses a device, and performs no App Store operation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
from datetime import datetime, timezone


def clean_environment():
    result = {key: os.environ[key] for key in
              ('HOME', 'USER', 'LOGNAME', 'TMPDIR', '__CF_USER_TEXT_ENCODING') if os.environ.get(key)}
    if not Path(result.get('HOME', '')).is_absolute():
        raise ValueError('An existing absolute HOME is required')
    result.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',
                  DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
                  LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', TERM='dumb')
    return result


def run(*arguments, cwd=None, log=None, check=True):
    command = [str(value) for value in arguments]
    if log:
        with Path(log).open('w') as output:
            completed = subprocess.run(command, cwd=cwd, env=clean_environment(),
                                       stdout=output, stderr=subprocess.STDOUT, check=check)
        return completed
    return subprocess.run(command, cwd=cwd, env=clean_environment(), capture_output=True,
                          text=True, check=check).stdout.strip()


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def now():
    return datetime.now(timezone.utc).isoformat()


def committed_source(root):
    if run('git', 'status', '--porcelain', cwd=root):
        raise ValueError('Commit repository changes before producing final assets')
    if run('git', 'branch', '--show-current', cwd=root) == 'main':
        raise ValueError('Use the issue branch, not main')
    return run('git', 'rev-parse', 'HEAD', cwd=root)


def bundle_inventory(app):
    app = Path(app).resolve()
    if list(app.rglob('*.xctest')):
        raise ValueError(f'The final app contains an XCTest bundle: {app}')
    files = {str(path.relative_to(app)): sha256(path) for path in sorted(app.rglob('*')) if path.is_file()}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    bundles = [app] + sorted(path for path in app.rglob('*') if path.suffix in ('.app', '.appex'))
    signatures = []
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if info['CFBundleShortVersionString'] != '2.0.0' or int(info['CFBundleVersion']) < 5:
            raise ValueError(f'Unexpected version in {bundle}')
        run('codesign', '--verify', '--strict', bundle)
        signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(bundle)],
                                   env=clean_environment(), text=True, capture_output=True, check=True)
        signatures.append({'bundle': str(bundle.relative_to(app)), 'identifier': info['CFBundleIdentifier'],
                           'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                           'signature': signature.stderr, 'privacy_manifest': (bundle / 'PrivacyInfo.xcprivacy').exists()})
    return {'path': str(app), 'sha256': digest, 'files': files, 'bundles': signatures}


def read_devices(path):
    devices = json.loads(Path(path).read_text())
    available = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))
    by_id = {device['udid']: device for group in available['devices'].values() for device in group}
    for family, device in devices.items():
        actual = by_id[device['simulator_udid']]
        if device.get('owner') != 'issue-469' or not actual['name'].startswith('CodexBar-469-'):
            raise ValueError(f'Not an issue-owned {family} simulator')
    return devices


def build(args):
    source = committed_source(args.root)
    work = args.work_dir.resolve()
    if work.is_relative_to(args.root.resolve()):
        raise ValueError('Native build products belong outside the repository')
    work.mkdir(parents=True, exist_ok=True)
    devices = read_devices(args.devices)
    commands = []
    apps = {}
    for family, scheme, platform, product in [
        ('iphone', 'CodexBarStorefrontAssets', 'iOS Simulator', 'Debug-iphonesimulator/CodexBarIOS.app'),
        ('watch', 'CodexBarWatch', 'watchOS Simulator', 'Debug-watchsimulator/CodexBarWatch.app'),
    ]:
        derived = work / f'{family}-final-build'
        command = ['xcodebuild', '-project', str(args.root / 'CodexBarIOS.xcodeproj'), '-scheme', scheme,
                   '-configuration', 'Debug', '-skipPackagePluginValidation',
                   '-destination', f"platform={platform},id={devices[family]['simulator_udid']}",
                   '-derivedDataPath', str(derived), '-parallel-testing-enabled', 'NO',
                   '-maximum-concurrent-test-simulator-destinations', '1',
                   'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'SWIFT_STRICT_CONCURRENCY=complete',
                   'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'clean',
                   'build-for-testing' if family == 'iphone' else 'build']
        log = work / f'{family}-final-build.log'
        print(f'Building {family} at {source}; log: {log}', flush=True)
        run(*command, cwd=args.root, log=log)
        commands.append({'arguments': command, 'log': str(log), 'log_sha256': sha256(log)})
        apps[family] = bundle_inventory(derived / 'Build/Products' / product)
        if committed_source(args.root) != source:
            raise ValueError('Source changed during the final build')
    source_files = {name: sha256(args.root / name) for name in
                    run('git', 'ls-files', cwd=args.root).splitlines() if (args.root / name).is_file()}
    receipt = {'source_commit': source, 'source_files': source_files, 'apps': apps, 'build': '5',
               'xcode': run('xcodebuild', '-version'), 'devices': devices, 'commands': commands,
               'completed_at': now(), 'environment_keys': sorted(clean_environment())}
    write_json(work / 'build-provenance.json', receipt)
    print(work / 'build-provenance.json', flush=True)


def wait_ready(path, scene):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if path.exists() and path.read_text() == scene:
            return
        time.sleep(0.5)
    raise TimeoutError(f'The app did not finish the {scene} fixture: {path}')


def capture(args):
    source = committed_source(args.root)
    build_receipt = json.loads(args.build_receipt.read_text())
    if build_receipt['source_commit'] != source:
        raise ValueError('Build and checked-out source revisions differ')
    for info in build_receipt['apps'].values():
        if bundle_inventory(info['path'])['sha256'] != info['sha256']:
            raise ValueError('Final build has changed')
    manifest = json.loads(args.manifest.read_text())
    devices = read_devices(args.devices)
    receipt = {key: build_receipt[key] for key in ('source_commit', 'build', 'xcode')}
    receipt.update(devices=devices, captures={}, build_receipt_sha256=sha256(args.build_receipt))
    write_json(args.receipt, receipt)
    for family in dict.fromkeys(asset['device'] for asset in manifest['assets']):
        device = devices[family]
        udid = device['simulator_udid']
        watch = family == 'watch'
        app = build_receipt['apps']['watch' if watch else 'iphone']['path']
        bundle_id = 'com.hemsoft.CodexBarIOS.watchkitapp' if watch else 'com.hemsoft.CodexBarIOS'
        run('xcrun', 'simctl', 'boot', udid, check=False)
        run('xcrun', 'simctl', 'bootstatus', udid, '-b')
        runtime_root = run('xcrun', 'simctl', 'getenv', udid, 'SIMULATOR_ROOT')
        system_version = Path(runtime_root) / 'System/Library/CoreServices/SystemVersion.plist'
        if system_version.exists():
            device['runtime_system_version'] = plistlib.loads(system_version.read_bytes())
        if not watch:
            run('xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
                '--wifiBars', '3', '--cellularBars', '4', '--batteryState', 'charged', '--batteryLevel', '100')
        run('xcrun', 'simctl', 'install', udid, app)
        installed = run('xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'app')
        if bundle_inventory(installed)['sha256'] != build_receipt['apps']['watch' if watch else 'iphone']['sha256']:
            raise ValueError(f'The installed {family} app differs from the final build')
        container = Path(run('xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'data'))
        ready = container / 'Library/Caches' / ('app-store-watch-screenshot-ready' if watch else 'app-store-screenshot-ready')
        for asset in (item for item in manifest['assets'] if item['device'] == family):
            output = (args.output_root / asset['raw_path']).resolve()
            if not output.is_relative_to(args.output_root.resolve()) or output.exists():
                raise ValueError(f'Refusing to overwrite or escape asset output: {output}')
            output.parent.mkdir(parents=True, exist_ok=True)
            ready.unlink(missing_ok=True)
            ready.with_suffix('.json').unlink(missing_ok=True)
            if not watch:
                run('xcrun', 'simctl', 'ui', udid, 'appearance', asset['appearance'])
            launch = ['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, bundle_id,
                      '--app-store-screenshots', '--app-store-watch-scene' if watch else '--app-store-scene', asset['scene'],
                      '--app-store-appearance', asset['appearance'], '--app-store-settle-seconds', '3',
                      '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
            print(f"Capturing {asset['id']}", flush=True)
            run(*launch)
            wait_ready(ready, asset['scene'])
            fixture = {'scene': asset['scene'], 'layout': 'native unlocked Watch sample', 'providerData': 'synthetic'}
            if not watch:
                fixture = json.loads(ready.with_suffix('.json').read_text())
                pro = asset['entitlement_fixture'] == 'synthetic-pro'
                if not fixture['isResolved'] or fixture['hasProAccess'] != pro or fixture['historyDayLimit'] != (90 if pro else 7):
                    raise ValueError('Rendered entitlement does not match the caption')
                if not pro and fixture['visibleAccountCount'] != 1:
                    raise ValueError('The Free scene must contain exactly one account')
            native = args.receipt.parent / 'native-originals' / output.name
            native.parent.mkdir(parents=True, exist_ok=True)
            if native.exists():
                raise ValueError(f'Refusing to overwrite native capture: {native}')
            run('xcrun', 'simctl', 'io', udid, 'screenshot', '--type=png', native)
            run(args.root / 'scripts/flatten-storefront-image.sh', native, output)
            receipt['captures'][asset['id']] = {
                'raw_sha256': sha256(output), 'scene': asset['scene'], 'appearance': asset['appearance'],
                'entitlement_fixture': asset['entitlement_fixture'], 'captured_at': now(), 'source_commit': source,
                'fixture_receipt': fixture, 'application_sha256': build_receipt['apps']['watch' if watch else 'iphone']['sha256'],
                'raw_path': str(output), 'launch_arguments': launch,
                'native_path': str(native), 'native_sha256': sha256(native),
            }
            write_json(args.receipt, receipt)
        run('xcrun', 'simctl', 'terminate', udid, bundle_id)
    if committed_source(args.root) != source:
        raise ValueError('Source changed during capture')
    print(f"Captured {len(receipt['captures'])} native images; receipt: {args.receipt}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('build', 'capture'))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--devices', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--build-receipt', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    required = ('work_dir',) if args.action == 'build' else ('build_receipt', 'manifest', 'output_root', 'receipt')
    for field in required:
        if getattr(args, field) is None:
            parser.error(f'--{field.replace("_", "-")} is required for {args.action}')
    (build if args.action == 'build' else capture)(args)


if __name__ == '__main__':
    main()
