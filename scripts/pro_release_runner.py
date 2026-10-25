#!/usr/bin/env python3
"""Explicit manual release phases; owns only newly provisioned simulators."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
import re
import selectors
import shutil
import signal
import time
from pathlib import Path
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

from release_evidence import (QUALIFIED_IOS_RUNTIME, ROOT, capture, digest, discovery_tests, load_manifest, now, read,
                              require_pinned, source_snapshot, toolchain, unique_tests,
                              validate_device, validate_receipt, validate_results, write)


class PhaseFailure(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code or 1


def persist(path, value, primary=None):
    """Required telemetry fails the gate but cannot replace an earlier exit."""
    try:
        write(path, value)
    except OSError as error:
        message = f'Could not save required evidence {path}: {error}'
        print(message, file=sys.stderr)
        return PhaseFailure(f'{primary}; {message}' if primary else message,
                            getattr(primary, 'code', 1))
    return primary


def command(output, name, argv):
    """Never reuse a command log; keep the first failure and its actual exit."""
    receipt = dict(command=argv, started=now())
    log = output / f'{name}.log'
    print(f'{name}: {log}', flush=True)
    with log.open('x') as stream:
        result = subprocess.run(argv, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    receipt.update(ended=now(), exit=result.returncode)
    failure = PhaseFailure(f'{name} failed ({result.returncode}); retained {log}', result.returncode) if result.returncode else None
    failure = persist(output / f'{name}.command.json', receipt, failure)
    if result.returncode:
        try:
            print(log.read_text()[-12000:], file=sys.stderr)
        except OSError as error:
            print(f'Cannot read failure log {log}: {error}', file=sys.stderr)
    if failure:
        raise failure
    return receipt


def json_command(output, name, argv):
    command(output, name, argv)
    value = json.loads((output / f'{name}.log').read_text())
    write(output / f'{name}.json', value)
    return value


def device_record(identifier, family, tools, runtime_path=None):
    inventory = json.loads(capture(['xcrun', 'simctl', 'list', '--json']))
    matches = [(runtime, device) for runtime in inventory['runtimes']
               if runtime['isAvailable'] and (runtime_path is None or runtime['bundlePath'] == runtime_path)
               for device in inventory['devices'].get(runtime['identifier'], [])
               if device['udid'] == identifier and device['isAvailable']]
    if len(matches) != 1:
        raise ValueError(f'Simulator runtime is unavailable or ambiguous: {identifier}; use an owned runtime receipt')
    runtime, device = matches[0]
    model = next(item['name'] for item in inventory['devicetypes']
                 if item['identifier'] == device['deviceTypeIdentifier'])
    result = dict(deviceId=identifier, deviceName=device['name'], modelName=model,
                  osVersion=runtime['version'], osBuildNumber=runtime['buildversion'],
                  architecture=tools['architecture'], platform='iOS Simulator', family=family,
                  runtime=runtime['identifier'], runtimeBundlePath=runtime['bundlePath'], state=device['state'])
    validate_device(result, result)
    return result


def provision(output, family, tools, supplementary=False, runtime_build=None):
    inventory = json.loads(capture(['xcrun', 'simctl', 'list', '--json']))
    version = lambda value: tuple(int(part) for part in value.split('.'))
    runtimes = [runtime for runtime in inventory['runtimes'] if runtime['isAvailable']
                and runtime['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
                and version(runtime['version']) <= version(tools['sdk'])]
    if not supplementary:
        require_pinned(tools)
        runtimes = [runtime for runtime in runtimes if runtime['version'] == QUALIFIED_IOS_RUNTIME['version']
                    and runtime['buildversion'] == QUALIFIED_IOS_RUNTIME['build']]
    if runtime_build:
        runtimes = [runtime for runtime in runtimes if runtime['buildversion'] == runtime_build]
    if not runtimes:
        raise ValueError('No compatible qualified iOS runtime; do not substitute a different runtime')
    latest = max(version(runtime['version']) for runtime in runtimes)
    runtimes = [runtime for runtime in runtimes if version(runtime['version']) == latest]
    if len(runtimes) != 1:
        raise ValueError('Ambiguous runtime builds; select an observed --runtime-build before provisioning')
    runtime = runtimes[0]
    prefix = 'iPhone' if family == 'iphone' else 'iPad'
    # Use a device type actually present for this runtime, without touching that device.
    candidates = [device for device in inventory['devices'].get(runtime['identifier'], [])
                  if device['isAvailable'] and any(item['identifier'] == device['deviceTypeIdentifier']
                  and item['name'].startswith(prefix) for item in inventory['devicetypes'])]
    if not candidates:
        raise ValueError(f'No known compatible {family} device type for {runtime["identifier"]}')
    device_type = sorted(candidates, key=lambda item: (item['deviceTypeIdentifier'], item['udid']))[-1]['deviceTypeIdentifier']
    name = f'CodexBar 470 {family} {uuid.uuid4().hex[:10]}'
    # simctl supports an exact runtime bundle path. Version identifiers can
    # name several installed beta/release builds and must not choose implicitly.
    receipt = command(output, 'create-device', ['xcrun', 'simctl', 'create', name, device_type, runtime['bundlePath']])
    identifier = (output / 'create-device.log').read_text().strip()
    if not re_uuid(identifier):
        raise ValueError('simctl create did not return one UUID; inspect create-device.log')
    device = device_record(identifier, family, tools, runtime['bundlePath'])
    write(output / 'ownership.json', dict(schema=1, owner=str(ROOT), created=receipt,
                                         tools=tools, device=device, supplementary=supplementary))
    print(f'Created owned simulator: {name} ({identifier}); {output / "ownership.json"}', flush=True)
    return device


def re_uuid(value):
    try:
        return str(uuid.UUID(value)).upper() == value.upper()
    except ValueError:
        return False


def owned_device(path, tools, allow_quarantined=False):
    receipt = read(path)
    if (path.parent / 'native-use.json').exists() and not allow_quarantined:
        raise ValueError('Owned simulator already used for native execution; preserve it and provision a fresh device')
    prior_outcome = path.parent / 'outcome.json'
    if prior_outcome.exists() and read(prior_outcome).get('deviceReusable') is False and not allow_quarantined:
        raise ValueError('This owned simulator is quarantined after failed/incomplete native execution')
    if receipt.get('owner') != str(ROOT) or receipt.get('tools') != tools or receipt.get('created', {}).get('exit') != 0:
        raise ValueError('Ownership receipt belongs to another checkout/toolchain or failed creation')
    expected = receipt['device']
    argv = receipt['created']['command']
    if argv != ['xcrun', 'simctl', 'create', expected['deviceName'], argv[4], expected['runtimeBundlePath']]:
        raise ValueError('Invalid simulator creation receipt')
    actual = device_record(expected['deviceId'], expected['family'], tools, expected['runtimeBundlePath'])
    validate_device(actual, expected)
    if actual['deviceName'] != expected['deviceName'] or not actual['deviceName'].startswith('CodexBar 470 '):
        raise ValueError('Simulator ownership name changed')
    return actual


def claim_native_device(ownership, output, device):
    # One native run per owned simulator. This marker is created before work,
    # so interruption or a failed outcome write cannot allow unsafe reuse.
    with (ownership.parent / 'native-use.json').open('x') as stream:
        json.dump(dict(deviceId=device['deviceId'], output=str(output), started=now()), stream)


def shutdown(output, device):
    current = device_record(device['deviceId'], device['family'], toolchain(), device.get('runtimeBundlePath'))
    validate_device(current, device)
    if current['state'] != 'Shutdown':
        command(output, 'shutdown-device', ['xcrun', 'simctl', 'shutdown', device['deviceId']])


def native_host_contract():
    path = ROOT / 'CodexBarIOS.xcodeproj/xcshareddata/xcschemes/CodexBarProNativeCommerce.xcscheme'
    action = ET.parse(path).getroot().find('TestAction')
    flags = action.findall('./EnvironmentVariables/EnvironmentVariable')
    if action.get('buildConfiguration') != 'Debug' or not any(
            flag.get('key') == 'CODEXBAR_NATIVE_STOREKIT_TEST_HOST' and flag.get('value') == '1'
            and flag.get('isEnabled') == 'YES' for flag in flags):
        raise ValueError('Native scheme must enable the isolated Debug StoreKit host')


def binaries(derived, signed):
    products = derived / 'Build/Products'
    apps = sorted(products.rglob('*.app'))
    tests = sorted(products.rglob('*.xctest'))
    configurations = sorted(products.rglob('*.xctestrun'))
    if not apps or not tests or not configurations:
        raise ValueError('Build must produce apps, test bundles and xctestrun configurations')
    result = []
    for bundle in apps + tests:
        signature = subprocess.run(['codesign', '-dvvv', str(bundle)], capture_output=True, text=True)
        if signed:
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True, capture_output=True)
            if signature.returncode or 'Signature=adhoc' not in signature.stderr:
                raise ValueError(f'Native simulator host is not ad hoc signed: {bundle}')
        result.append(dict(path=str(bundle), kind=bundle.suffix, sha256=digest(bundle), signature=signature.stderr,
                           signatureExit=signature.returncode,
                           files={str(path.relative_to(bundle)): digest(path) for path in sorted(bundle.rglob('*'))
                                  if path.is_file()}))
    result.extend(dict(path=str(path), kind='.xctestrun', sha256=digest(path)) for path in configurations)
    return result


# Native observation is manual-only and cannot alter XCTest's verdict.
OBSERVER_PHASES = {'ui-native', 'ui-native-purchase-error'}
OBSERVER_SUBSYSTEM = 'com.hemsoft.CodexBarIOS.native-readiness'
OBSERVER_PREFIX = 'CB517NATIVE '
OBSERVER_LIMITS = dict(commandSeconds=15, phaseSeconds=60, stdoutBytes=8 * 1024 * 1024,
                       # Known retained export is197059893bytes; only the bounded session survives staging.
                       exportBytes=256 * 1024 * 1024, exportFiles=2048, sessionBytes=32 * 1024 * 1024)


def observer_export_cap(export):
    if export and export.exists():
        size = 0
        for count, path in enumerate(export.rglob('*'), 1):
            if count > OBSERVER_LIMITS['exportFiles'] or path.is_symlink():
                raise ValueError('Observer export byte/file cap exceeded')
            if path.is_file():
                size += path.stat().st_size
            if size > OBSERVER_LIMITS['exportBytes']:
                raise ValueError('Observer export byte/file cap exceeded')


def observer_clock(row):
    keys = ('wallBefore', 'uptime', 'wallAfter')
    if (row.get('schema') != 1 or any(type(row.get(key)) not in (int, float)
            or not math.isfinite(row[key]) for key in keys) or row['wallAfter'] < row['wallBefore']):
        raise ValueError('Invalid observer clock tuple')


def observer_command(folder, label, argv, deadline, export=None):
    """Finite process-group lifetime and byte/file caps, including partial output."""
    start = time.monotonic()
    receipt = dict(command=argv, started=now(), limits=OBSERVER_LIMITS, complete=False, truncated=False, timedOut=False)
    path = folder / (label + '.json')
    failure, process = None, None
    stdout, stderr = bytearray(), bytearray()
    try:
        if time.monotonic() >= deadline:
            raise ValueError('Observer phase deadline exhausted before command')
        with selectors.DefaultSelector() as selector:
            process = subprocess.Popen(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            selector.register(process.stdout, selectors.EVENT_READ, stdout)
            selector.register(process.stderr, selectors.EVENT_READ, stderr)
            end = min(deadline, time.monotonic() + OBSERVER_LIMITS['commandSeconds'])
            while selector.get_map():
                if time.monotonic() >= end:
                    raise ValueError('Observer command deadline exceeded')
                observer_export_cap(export)
                for key, _ in selector.select(timeout=min(0.05, max(0, end - time.monotonic()))):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        remaining = OBSERVER_LIMITS['stdoutBytes'] - len(stdout) - len(stderr)
                        key.data.extend(block[:max(0, remaining)])
                        if len(block) > remaining:
                            raise ValueError('Observer output byte cap exceeded; partial output retained')
            process.wait(timeout=max(0.001, end - time.monotonic()))
            observer_export_cap(export)
            if process.returncode:
                raise ValueError(f'Observer command exited {process.returncode}')
            receipt['complete'] = True
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        failure = PhaseFailure(str(error))
        receipt.update(error=str(error), truncated='cap exceeded' in str(error),
                       timedOut='deadline' in str(error) or isinstance(error, subprocess.TimeoutExpired))
    finally:
        cleanup_errors = []
        if process:
            # Each step uses only this retained Popen handle, once. A failed
            # kill/wait/close must not skip the other cleanup or erase evidence.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                cleanup_errors.append(dict(step='kill', error=str(error)))
            try:
                process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_errors.append(dict(step='wait', error=str(error)))
            receipt['exit'] = process.returncode
            for name, pipe in (('stdout', process.stdout), ('stderr', process.stderr)):
                try:
                    pipe.close()
                except OSError as error:
                    cleanup_errors.append(dict(step=name, error=str(error)))
        if cleanup_errors:
            receipt.update(complete=False, cleanupErrors=cleanup_errors)
            details = '; '.join(item['step'] + ': ' + item['error'] for item in cleanup_errors)
            message = 'Observer cleanup failed: ' + details
            failure = PhaseFailure(f'{failure}; {message}' if failure else message, getattr(failure, 'code', 1))
            receipt.setdefault('error', message)
        receipt.update(ended=now(), seconds=time.monotonic() - start, stdoutBytes=len(stdout), stderrBytes=len(stderr))
        write_errors = []
        for name, data in (('stdout', stdout), ('stderr', stderr)):
            try:
                (folder / (label + '.' + name)).write_bytes(data)
            except OSError as error:
                write_errors.append(dict(stream=name, error=str(error)))
        if write_errors:
            receipt.update(complete=False, writeErrors=write_errors)
            details = '; '.join(item['stream'] + ': ' + item['error'] for item in write_errors)
            message = 'Observer output write failed: ' + details
            failure = PhaseFailure(f'{failure}; {message}' if failure else message, getattr(failure, 'code', 1))
            receipt.setdefault('error', message)
        failure = persist(path, receipt, failure)
    if failure:
        raise failure
    return bytes(stdout)


def observer_runner_records(path):
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Native XCTest log exceeds observer parse cap')
    records = []
    for line in path.read_text().splitlines():
        if 'CB517RUNNER ' not in line:
            continue
        record = json.loads(line.split('CB517RUNNER ', 1)[1])
        if (not isinstance(record, dict) or record.get('stage') not in ('waitBegin', 'predicatePositive', 'waitEnd')
                or not re_uuid(record.get('run', '')) or type(record.get('pid')) is not int):
            raise ValueError('Invalid runner observation identity')
        observer_clock(record)
        records.append(record)
    if not records or not {'waitBegin', 'waitEnd'} <= {row['stage'] for row in records}:
        raise ValueError('Missing native wait boundary observations')
    return records


def collect_native_observer(runner, folder, result, receipt):
    """Read only the owned simulator, correlate app/runner UUID+PID, export before final hash."""
    output = folder / 'native-observer'
    output.mkdir()
    report = dict(schema=1, complete=False, limits=OBSERVER_LIMITS, source=runner.source,
                  device=runner.device, tools=runner.tools, phase=receipt['phase'],
                  started=receipt['started'], ended=receipt['ended'])
    failure = None
    staging = output / 'offline-export'
    try:
        deadline = time.monotonic() + OBSERVER_LIMITS['phaseSeconds']
        require_pinned(runner.tools, runner.device)
        developer = Path(runner.tools['developer_dir']).resolve()
        if Path(os.environ.get('DEVELOPER_DIR', '')).resolve() != developer:
            raise ValueError('Observer DEVELOPER_DIR differs from qualified build')
        ownership = read(runner.ownership)
        created = ownership.get('created', {})
        argv = created.get('command', [])
        if (ownership.get('owner') != str(ROOT) or ownership.get('tools') != runner.tools
                or created.get('exit') != 0
                or len(argv) != 6 or argv[:3] != ['xcrun', 'simctl', 'create']
                or argv[3] != runner.device['deviceName'] or argv[5] != runner.device['runtimeBundlePath']
                or not re_uuid(runner.device['deviceId'])):
            raise ValueError('Observer lacks exact simulator ownership')
        validate_device(ownership['device'], runner.device)
        if ownership['device']['deviceName'] != runner.device['deviceName']:
            raise ValueError('Observer simulator name changed')
        used = read(runner.ownership.parent / 'native-use.json')
        if used.get('deviceId') != runner.device['deviceId'] or used.get('output') != str(runner.output):
            raise ValueError('Observer native claim differs')
        for tool in ('simctl', 'xcresulttool'):
            found = observer_command(output, 'find-' + tool, ['/usr/bin/xcrun', '--find', tool], deadline)
            if Path(found.decode().strip()).resolve() != developer / 'usr/bin' / tool:
                raise ValueError('Observer tool outside qualified developer directory')
        records = observer_runner_records(folder / 'xcodebuild.log')
        runs = {row['run'] for row in records}
        if len(runs) != 1 or len({row['pid'] for row in records}) != 1:
            raise ValueError('Ambiguous native runner identity')
        report['runner'] = records
        interval = [datetime.fromisoformat(receipt[key]).astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.%f+0000')
                    for key in ('started', 'ended')]
        prefix = ['/usr/bin/xcrun', 'simctl', 'spawn', runner.device['deviceId'], 'log', 'show', '--style', 'json',
                  '--start', interval[0], '--end', interval[1]]
        raw = observer_command(output, 'app-trace', prefix + ['--predicate', f'subsystem == "{OBSERVER_SUBSYSTEM}"'], deadline)
        events = json.loads(raw)
        if not isinstance(events, list):
            raise ValueError('Observer log is not a JSON event list')
        app = []
        for event in events:
            if not isinstance(event, dict):
                raise ValueError('Invalid app log event shape')
            message = event.get('eventMessage', '')
            if not isinstance(message, str):
                raise ValueError('Invalid app event message shape')
            if not message.startswith(OBSERVER_PREFIX):
                continue
            row = json.loads(message[len(OBSERVER_PREFIX):])
            if (not isinstance(row, dict) or row.get('run') not in runs or row.get('pid') != event.get('processID')
                    or not event.get('processImagePath', '').endswith('/CodexBarIOS.app/CodexBarIOS')
                    or not re_uuid(row.get('launch', ''))):
                raise ValueError('Observer app identity differs from runner')
            observer_clock(row)
            app.append(dict(marker=row, timestamp=event.get('timestamp'), bootUUID=event.get('bootUUID'),
                            processImageUUID=event.get('processImageUUID')))
        if not app or len({row['marker']['pid'] for row in app}) != 1 or len({row['marker']['launch'] for row in app}) != 1:
            raise ValueError('Missing or ambiguous native app trace')
        report['app'] = app
        app_pid = app[0]['marker']['pid']
        # Strictly this app, not storekitd/trustd or other applications/accounts.
        predicate = f'processID == {app_pid} AND (subsystem == "com.apple.securityd" OR subsystem == "com.apple.storekit")'
        security = observer_command(output, 'app-sdk', prefix + ['--predicate', predicate], deadline)
        sdk_events = json.loads(security)
        if not isinstance(sdk_events, list):
            raise ValueError('App SDK log is not a JSON list')
        report['sdkEventCount'] = len(sdk_events)
        if not result.exists():
            raise ValueError('No native xcresult for offline session export')
        observer_command(output, 'session-export', ['/usr/bin/xcrun', 'xcresulttool', 'export', 'diagnostics',
                         '--path', str(result), '--output-path', str(staging)], deadline, export=staging)
        # Offline extraction of already-captured xcresult diagnostics, no new sysdiagnose/host collection.
        # Retain only this test bundle's Session logs. Other exported copies are removed below.
        sessions = [path for path in staging.rglob('Session-*.log')
                    if any(part.startswith('CodexBarIOSUITests-') for part in path.parts)]
        if len(sessions) != 1:
            raise ValueError('Missing or ambiguous XCTest session log')
        report['sessionBytes'] = sessions[0].stat().st_size
        if report['sessionBytes'] > OBSERVER_LIMITS['sessionBytes']:
            raise ValueError('XCTest session byte cap exceeded')
        target = output / 'xctest-session.log'
        shutil.copyfile(sessions[0], target)
        session_text = target.read_text()
        runner_pid = records[0]['pid']
        if f'CodexBarIOSUITests-Runner[{runner_pid}:' not in session_text or not re.search(rf'pid:\s*{app_pid}\b', session_text):
            raise ValueError('XCTest session does not bind observed runner/app PIDs')
        report['sessionSha256'] = digest(target)
        stages = {row['marker']['stage'] for row in app}
        if receipt.get('exit') == 0 and (not {'snapshotBegin', 'snapshotEnd', 'catalogBegin', 'catalogEnd', 'viewReadiness'} <= stages
                or 'predicatePositive' not in {row['stage'] for row in records}
                or not any(row['marker']['stage'] == 'viewReadiness' and row['marker'].get('count', 0) & 1 for row in app)):
            raise ValueError('Passing native run lacks required app observations')
        report['complete'] = True
    except (ValueError, KeyError, TypeError, OSError, PhaseFailure) as error:
        failure = error if isinstance(error, PhaseFailure) else PhaseFailure(str(error))
        report['error'] = str(error)
    finally:
        try:
            if staging.exists():
                shutil.rmtree(staging)
        except OSError as error:
            report.update(complete=False, cleanupError=str(error))
            failure = failure or PhaseFailure(str(error))
        failure = persist(output / 'receipt.json', report, failure)
    if failure:
        raise failure
    return report



class Runner:
    def __init__(self, output, device, source, tools, ownership=None):
        self.output, self.device, self.source, self.tools = output, device, source, tools
        self.ownership = Path(ownership).resolve() if ownership is not None else output / 'ownership.json'
        self.manifest = load_manifest()
        self.receipts = []

    def unchanged(self):
        if source_snapshot(require_clean=not bool(self.source['status'])) != self.source:
            raise ValueError('Source changed during validation; keep this run and start a fresh one')

    def arguments(self, scheme, derived, tests=(), native=False):
        if scheme == 'CodexBarProNativeCommerce' and not tests:
            raise ValueError('Never execute the native scheme unfiltered')
        return ['xcodebuild', '-project', str(ROOT / 'CodexBarIOS.xcodeproj'), '-scheme', scheme,
                '-configuration', 'Debug', '-skipPackagePluginValidation',
                '-destination', f'platform=iOS Simulator,id={self.device["deviceId"]}',
                '-derivedDataPath', str(derived), '-parallel-testing-enabled', 'NO',
                '-maximum-concurrent-test-simulator-destinations', '1', '-enableCodeCoverage', 'YES',
                *['-only-testing:' + test for test in tests],
                'CODE_SIGNING_ALLOWED=' + ('YES' if native else 'NO'),
                *(['CODE_SIGN_IDENTITY=-', 'SWIFT_STRICT_CONCURRENCY=complete'] if native else [])]

    def build(self, label, scheme, tests=(), native=False):
        self.unchanged()
        if native:
            native_host_contract()
        derived = self.output / f'DerivedData-{label}'
        if derived.exists():
            raise ValueError(f'Refusing old DerivedData: {derived}')
        argv = self.arguments(scheme, derived, tests, native) + ['build-for-testing']
        receipt = dict(schema=1, source=self.source, tools=self.tools, device=self.device,
                       configuration='Debug', coverage=True, native=native, scheme=scheme,
                       derivedData=str(derived), started=now(), command=argv)
        path = self.output / f'build-{label}.json'
        failure = None
        try:
            receipt.update(command(self.output, f'build-{label}', argv))
            self.unchanged()
            receipt['binaries'] = binaries(derived, native)
            receipt['adhocSigned'] = native
        except (PhaseFailure, ValueError, subprocess.CalledProcessError) as error:
            failure = error if isinstance(error, PhaseFailure) else PhaseFailure(str(error))
            receipt.update(exit=failure.code, error=str(error))
        finally:
            receipt['ended'] = now()
            failure = persist(path, receipt, failure)
        if failure:
            raise failure
        return path

    def restart_storekit(self, folder, name):
        """Each xcodebuild reinstalls the app. storekitd can keep the previous install's dead
        container, reject the receipt and fall back to sandbox requests (#500). Stopping it
        lets launchd start a fresh instance on demand; a shut-down device has none running.
        Only preparation and adapter phases restart it: they configure SKTestSession in-process."""
        current = device_record(self.device['deviceId'], self.device['family'], self.tools,
                                self.device.get('runtimeBundlePath'))
        if current['state'] == 'Booted':
            command(folder, name, ['xcrun', 'simctl', 'spawn', self.device['deviceId'],
                                   'launchctl', 'stop', 'com.apple.storekitd'])

    def phase(self, name, build_path, base=False):
        self.unchanged()
        build = read(build_path)
        if build.get('source') != self.source or build.get('tools') != self.tools or build.get('exit') != 0:
            raise ValueError('Phase build source/toolchain/result differs')
        validate_device(build['device'], self.device)
        if build.get('configuration') != 'Debug' or build.get('coverage') is not True:
            raise ValueError('Phase requires an instrumented Debug build')
        for binary in build['binaries']:
            if digest(binary['path']) != binary['sha256']:
                raise ValueError('Built app changed before test execution')
        phase = self.manifest['phases'].get(name)
        tests = phase['tests'] if phase else []
        scheme = phase['scheme'] if phase else 'CodexBarIOS'
        if scheme != build['scheme']:
            raise ValueError('Phase and build schemes differ')
        folder = self.output if base else self.output / name
        if not base:
            folder.mkdir()
        result = folder / ('CodexBarIOSUITests.xcresult' if base else 'result.xcresult')
        argv = self.arguments(scheme, Path(build['derivedData']), tests, build['native'])
        discovery = folder / 'discovery.json'
        discovery_argv = argv + ['test-without-building', '-enumerate-tests',
                '-test-enumeration-style', 'flat', '-test-enumeration-format', 'json',
                '-test-enumeration-output-path', str(discovery)]
        # Journeys consume the SKTestSession overrides (dialogs, storefront, simulated errors) that
        # their preparation left in storekitd; a restart would discard them (#502).
        restart_storekit = build['native'] and (phase or {}).get('kind') != 'journey'
        if restart_storekit:
            self.restart_storekit(folder, 'storekitd-before-discovery')
        command(folder, 'discovery', discovery_argv)
        discovered = discovery_tests(read(discovery))
        expected = sorted(tests) if phase else discovered
        if discovered != expected:
            raise ValueError(f'Discovery differs from phase manifest: {name}')
        if name == 'ios' and (not set(self.manifest['shared_pro_tests']).issubset(discovered)
                             or any(test.split('/')[1] in ('StoreKitProPreparationTests', 'StoreKitProStoreSourceTests',
                                       'StoreKitProStorefrontTests', 'StoreKitProFailureTests', 'StoreKitProSubscriptionTests')
                                    or not test.startswith('CodexBarIOSTests/') for test in discovered)):
            raise ValueError('Ordinary discovery is missing shared Pro cases or includes specialized cases')
        if build['native'] and all(test.startswith('CodexBarIOSTests/') for test in expected):
            argv += ['-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '90',
                     '-maximum-test-execution-time-allowance', '120']
        argv += ['-resultBundlePath', str(result), 'test-without-building']
        if restart_storekit:
            self.restart_storekit(folder, 'storekitd-before-test')
        receipt = dict(schema=1, phase=name, source=self.source, tools=self.tools, device=self.device,
                       platform='ios', configuration='Debug', expectedTests=expected, result=str(result),
                       buildReceipt=str(build_path), build_sha256=digest(build_path),
                       discovery=str(discovery), discovery_sha256=digest(discovery), discoveryCommand=discovery_argv,
                       command=argv, started=now())
        failure = None
        try:
            receipt.update(command(folder, 'xcodebuild', argv))
        except (PhaseFailure, OSError) as error:
            failure = error if isinstance(error, PhaseFailure) else PhaseFailure(str(error))
            receipt.update(exit=failure.code, error=str(error))
        receipt['ended'] = now()
        if name in OBSERVER_PHASES:
            try:
                receipt['nativeObserver'] = collect_native_observer(self, folder, result, receipt)
            except (PhaseFailure, ValueError, KeyError, TypeError, OSError) as error:
                receipt['observerError'] = str(error)
                failure = failure or (error if isinstance(error, PhaseFailure) else PhaseFailure(str(error)))
        try:
            if result.exists():
                receipt['result_initial_sha256'] = digest(result)
                summary = json_command(folder, 'summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)])
                tree = json_command(folder, 'tests', ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result)])
                receipt['executedTests'] = validate_results(summary, tree, expected, self.device, receipt['started'], receipt['ended'])
            else:
                raise ValueError('Test invocation produced no xcresult')
            self.unchanged()
        except (ValueError, KeyError, TypeError, OSError, PhaseFailure) as error:
            receipt['validationError'] = str(error)
            if failure is None:
                failure = PhaseFailure(str(error))
        if failure and result.exists():
            try:
                command(folder, 'attachments', ['xcrun', 'xcresulttool', 'export', 'attachments',
                        '--path', str(result), '--output-path', str(folder / 'failure-attachments')])
            except (PhaseFailure, OSError) as error:
                receipt['attachmentError'] = str(error)
        # xcresulttool lazily creates database.sqlite3 during inspection. Bind
        # the retained bundle only after every diagnostic read has completed.
        try:
            if result.exists():
                receipt['result_sha256'] = digest(result)
        except (ValueError, OSError) as error:
            receipt['digestError'] = str(error)
            failure = failure or PhaseFailure(str(error))
        receipt['exit'] = failure.code if failure else 0
        failure = persist(folder / 'receipt.json', receipt, failure)
        self.receipts.append(dict(phase=name, result=str(result), receipt=str(folder / 'receipt.json')))
        if failure:
            raise failure
        return receipt


def sequence(phases, execute, cleanup=None):
    primary, reset = None, None
    try:
        for phase in phases:
            execute(phase)
    except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        primary = error
    finally:
        if cleanup:
            try:
                cleanup()
            except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
                reset = error
    return dict(exit=getattr(primary or reset, 'code', 1) if primary or reset else 0,
                primaryFailure=str(primary) if primary else None, cleanupFailure=str(reset) if reset else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['provision', 'native', 'ui', 'base', 'probe', 'shutdown'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--family', choices=['iphone', 'ipad'], default='iphone')
    parser.add_argument('--ownership', type=Path)
    parser.add_argument('--base-results', type=Path)
    parser.add_argument('--device', help='Existing destination only for the original base runner')
    parser.add_argument('--runtime-build', help='Exact observed installed runtime build for new owned devices')
    parser.add_argument('--supplementary', action='store_true', help='Local diagnostics; never release qualification')
    parser.add_argument('--build-only', action='store_true', help='Compile native host only; no passing phase claim')
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    output = args.output.resolve()
    if args.mode == 'base' and output.is_dir() and not any(output.iterdir()):
        pass  # run-ui-tests.sh allocated this unique empty directory with mktemp.
    else:
        output.mkdir(parents=True, exist_ok=False)
    outcome = dict(exit=1, complete=False, mode=args.mode, started=now(), supplementary=args.supplementary)
    device, runner, native_build = None, None, None
    try:
        source, tools = source_snapshot(require_clean=args.mode not in ('base', 'shutdown')), toolchain()
        write(output / 'source.json', source)
        write(output / 'toolchain.json', tools)
        if args.mode != 'base' and not args.supplementary:
            require_pinned(tools)
        if args.runtime_build and (args.ownership or args.mode in ('base', 'ui', 'shutdown')):
            raise ValueError('--runtime-build applies only when creating a new owned device')
        if args.mode == 'base':
            if not args.device:
                raise ValueError('Base mode requires an explicit destination')
            device = owned_device(args.ownership, tools) if args.ownership else device_record(args.device, args.family, tools)
            if device['deviceId'] != args.device:
                raise ValueError('Base destination differs from the ownership receipt')
        elif args.ownership:
            device = owned_device(args.ownership, tools, allow_quarantined=args.mode == 'shutdown')
        elif args.mode in ('ui', 'shutdown'):
            raise ValueError('UI/shutdown requires the ownership receipt from provision')
        else:
            device = provision(output, args.family, tools, args.supplementary, args.runtime_build)
        if device['family'] != args.family:
            raise ValueError(f'Owned device family differs from requested {args.family}')
        if args.mode not in ('base', 'shutdown') and not args.supplementary:
            require_pinned(tools, device)
        write(output / 'device.json', device)
        if args.mode in ('native', 'probe', 'ui'):
            claim_native_device(args.ownership or output / 'ownership.json', output, device)
        if args.mode in ('provision', 'shutdown'):
            if args.mode == 'shutdown':
                shutdown(output, device)
            outcome.update(exit=0, complete=True)
        else:
            runner = Runner(output, device, source, tools, ownership=args.ownership)
            manifest = runner.manifest
            if args.mode == 'base':
                # Build the ordinary scheme's full test bundle (35 methods), then
                # select only 29 at enumeration/execution. Supplemental six reuse it.
                build = runner.build('base', 'CodexBarIOSUITests')
                runner.phase('ui-original', build, base=True)
            else:
                if args.mode == 'ui':
                    receipts = list(args.base_results.glob('*/receipt.json')) if args.base_results else []
                    receipts = [path for path in receipts if read(path).get('phase') == 'ui-original']
                    if len(receipts) != 1:
                        raise ValueError('UI requires exactly one fresh original-29 receipt')
                    base = read(receipts[0])
                    if base['source'] != source or base['tools'] != tools or base['exit'] != 0:
                        raise ValueError('Original UI phase source/toolchain/result differs')
                    validate_device(base['device'], device)
                    validate_receipt(base, source, tools, manifest['phases']['ui-original']['tests'],
                                     'ui-original', Path(base['result']))
                    validate_results(read(receipts[0].parent / 'summary.json'), read(receipts[0].parent / 'tests.json'),
                                     manifest['phases']['ui-original']['tests'], device, base['started'], base['ended'])
                    if digest(base['result']) != base['result_sha256']:
                        raise ValueError('Original UI result changed')
                    supplemental = Path(base['buildReceipt'])
                    synthetic = runner.build('synthetic', 'CodexBarProCommerce', manifest['phases']['ui-synthetic']['tests'])
                elif args.mode == 'native' and not args.build_only:
                    ordinary = runner.build('ios', 'CodexBarIOS')
                    runner.phase('ios', ordinary)
                native_tests = sorted(set(test for phase in manifest['phases'].values()
                                          if phase['scheme'] == 'CodexBarProNativeCommerce' for test in phase['tests']))
                native_build = runner.build('native', 'CodexBarProNativeCommerce', native_tests, native=True)
                if not args.build_only:
                    if args.mode == 'ui':
                        def execute(name):
                            build = supplemental if name == 'ui-supplemental' else synthetic if name == 'ui-synthetic' else native_build
                            runner.phase(name, build)
                        state = sequence(manifest['ui_phases'], execute,
                                         lambda: runner.phase(manifest['ui_cleanup'], native_build))
                        outcome.update(state)
                        if state['exit']:
                            raise PhaseFailure(state['primaryFailure'] or state['cleanupFailure'], state['exit'])
                    else:
                        names = ['native-preparation'] if args.mode == 'probe' else manifest['native_phases']
                        for name in names:
                            runner.phase(name, native_build)
                outcome['complete'] = args.mode != 'probe' and not args.build_only
            outcome.update(exit=0, complete=outcome.get('complete') or args.mode == 'base')
            required = (['ui-original'] if args.mode == 'base' else manifest['coverage_phases']
                        if args.mode == 'native' else manifest['ui_phases'] + [manifest['ui_cleanup']])
            if outcome['complete'] and [item['phase'] for item in runner.receipts] != required:
                raise ValueError('Completed phase receipts do not match the required execution schedule')
    except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        outcome['exit'] = getattr(error, 'code', 1)
        if 'primaryFailure' not in outcome:
            outcome['primaryFailure'] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        if device and args.mode in ('native', 'probe', 'ui'):
            try:
                shutdown(output, device)
            except (PhaseFailure, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
                outcome.update(shutdownFailure=str(error), exit=outcome['exit'] or getattr(error, 'code', 1))
            # Failed native setup/execution may bypass XCTest teardown. Keep the
            # owned device shut down and forbid reuse; never erase it or imply reset.
            outcome['deviceReusable'] = outcome['exit'] == 0 and args.mode != 'probe'
        outcome.update(ended=now(), phases=runner.receipts if runner else [])
        outcome['complete'] = outcome['complete'] and outcome['exit'] == 0
        primary = PhaseFailure(outcome.get('primaryFailure') or outcome.get('cleanupFailure') or 'Validation failed', outcome['exit']) if outcome['exit'] else None
        if runner and args.mode == 'native':
            primary = persist(output / 'coverage-inputs.json', dict(schema=1, platform='ios', complete=outcome['complete'],
                    source=runner.source, tools=runner.tools, inputs=runner.receipts), primary)
        if primary:
            outcome.update(exit=primary.code, complete=False)
        primary = persist(output / 'outcome.json', outcome, primary)
        if primary:
            outcome.update(exit=primary.code, complete=False)
    return outcome['exit']


if __name__ == '__main__':
    sys.exit(main())
