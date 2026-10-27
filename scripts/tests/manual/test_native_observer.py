"""Manual observer controls. No Xcode, simulator, provider, network or UI execution."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_pro_release_validation as FIXTURE
R = FIXTURE.RUNNER
E = FIXTURE.EVIDENCE


class NativePhaseFlowTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FIXTURE.RunnerCommandFailureTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f = self.fixture
        self.runner = self.f.runner
        original_fixture = FIXTURE.result_fixture
        def ui_fixture(identities):
            summary, tree, device = original_fixture(identities)
            if identities and identities[0].startswith('CodexBarIOSUITests/'):
                tree['testNodes'][0]['name'] = 'CodexBarIOSUITests'
            return summary, tree, device
        patcher = patch.object(FIXTURE, 'result_fixture', side_effect=ui_fixture)
        patcher.start(); self.addCleanup(patcher.stop)

    def test_primary_65_capture_failure_reset_failure_and_shutdown_all_remain_visible(self):
        self.f.exit_codes.update({'ui-native': 65, 'ui-reset': 66})
        with patch.object(R, 'collect_native_observer', side_effect=R.PhaseFailure('capture unavailable')):
            state = R.sequence(['ui-native'], lambda name: self.runner.phase(name, self.f.build),
                               lambda: self.runner.phase('ui-reset', self.f.build))
        with patch.object(R, 'toolchain', return_value={}):
            R.shutdown(self.f.root, self.f.device)
        self.assertEqual(state['exit'], 65)
        self.assertIn('66', state['cleanupFailure'])
        row = E.read(self.f.root / 'ui-native/receipt.json')
        self.assertEqual(row['exit'], 65)
        self.assertIn('capture unavailable', row['observerError'])
        self.assertTrue(any(call[-2:] == ['shutdown', self.f.device['deviceId']] for call in self.f.calls))

    def test_observer_export_changes_are_in_final_result_hash(self):
        def observe(runner, folder, result, receipt):
            (result / 'observer-index.sqlite').write_text('materialized during offline export')
            return {'complete': True}
        with patch.object(R, 'collect_native_observer', side_effect=observe):
            row = self.runner.phase('ui-native', self.f.build)
        self.assertEqual(row['result_sha256'], E.digest(row['result']))
        self.assertTrue((Path(row['result']) / 'observer-index.sqlite').exists())

    def test_missing_observation_on_pass_fails_phase_and_retains_reset(self):
        with patch.object(R, 'collect_native_observer', side_effect=R.PhaseFailure('missing trace')):
            state = R.sequence(['ui-native'], lambda name: self.runner.phase(name, self.f.build),
                               lambda: self.runner.phase('ui-reset', self.f.build))
        self.assertEqual(state['exit'], 1)
        self.assertEqual(E.read(self.f.root / 'ui-reset/receipt.json')['exit'], 0)

    def test_required_observer_receipt_write_failure_preserves_primary(self):
        self.f.exit_codes['ui-native'] = 65
        original = R.write
        def write(path, value):
            if path.name == 'receipt.json' and path.parent.name == 'ui-native':
                raise OSError('full receipt volume')
            original(path, value)
        with patch.object(R, 'write', side_effect=write), patch.object(R, 'collect_native_observer', return_value={'complete': True}):
            with self.assertRaises(R.PhaseFailure) as failure:
                self.runner.phase('ui-native', self.f.build)
        self.assertEqual(failure.exception.code, 65)

    def test_collection_never_runs_for_preparation_or_reset(self):
        with patch.object(R, 'collect_native_observer') as collector:
            for phase in ('ui-preparation', 'ui-reset', 'native-preparation'):
                self.runner.phase(phase, self.f.build)
        collector.assert_not_called()


class CollectorEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'ui-native'
        self.folder.mkdir()
        self.result = self.folder / 'result.xcresult'
        self.result.mkdir()
        self.device = dict(deviceId='10000000-0000-0000-0000-000000000001', deviceName='CodexBar 470 ipad test',
                           runtimeBundlePath='/qualified/runtime', family='ipad', architecture='arm64',
                           platform='iOS Simulator', osVersion='26.2', osBuildNumber='23C54', modelName='iPad mini (A17 Pro)')
        self.tools = {'developer_dir': '/Applications/Qualified.app/Contents/Developer'}
        self.runner = R.Runner(self.root, self.device, {}, self.tools)
        self.run_id = '10000000-0000-0000-0000-000000000002'
        self.records = [dict(schema=1, stage=stage, run=self.run_id, pid=20, wallBefore=100, uptime=10, wallAfter=100.001)
                        for stage in ('waitBegin', 'predicatePositive', 'waitEnd')]
        self.write_runner()
        self.receipt = dict(phase='ui-native', started='2026-10-25T01:00:00-04:00', ended='2026-10-25T01:01:00-04:00', exit=0)
        E.write(self.root / 'ownership.json', dict(owner=str(R.ROOT), tools=self.tools, device=self.device,
                created=dict(exit=0, command=['xcrun', 'simctl', 'create', self.device['deviceName'], 'type', '/qualified/runtime'])))
        E.write(self.root / 'native-use.json', dict(deviceId=self.device['deviceId'], output=str(self.root)))
        self.events = [dict(timestamp='2026-10-25 05:00:10.000000+0000', processID=10, processImagePath='/app/CodexBarIOS.app/CodexBarIOS',
                eventMessage=R.OBSERVER_PREFIX + json.dumps(dict(schema=1, stage=stage, run=self.run_id, pid=10, count=1, wallBefore=100, uptime=10, wallAfter=100.001,
                    launch='10000000-0000-0000-0000-000000000003')))
                for stage in ('snapshotBegin', 'snapshotEnd', 'catalogBegin', 'catalogEnd', 'viewReadiness')]
        self.commands = []
        self.patchers = [patch.object(R, 'require_pinned'),
                         patch.dict(os.environ, {'DEVELOPER_DIR': self.tools['developer_dir']}),
                         patch.object(R, 'observer_command', side_effect=self.command)]
        for p in self.patchers:
            p.start(); self.addCleanup(p.stop)

    def write_runner(self):
        (self.folder / 'xcodebuild.log').write_text(''.join('CB517RUNNER ' + json.dumps(r) + '\n' for r in self.records))

    def command(self, folder, label, argv, deadline, export=None):
        self.commands.append(argv)
        if label.startswith('find-'):
            return (self.tools['developer_dir'] + '/usr/bin/' + label[5:]).encode()
        if label == 'app-trace':
            return json.dumps(self.events).encode()
        if label == 'app-sdk':
            return b'[]'
        if label == 'session-export':
            target = export / 'CodexBarIOSUITests-session/Session-test.log'
            target.parent.mkdir(parents=True)
            target.write_text(f'CodexBarIOSUITests-Runner[20:123] requesting app (pid:{self.events[0]["processID"]})')
            (export / 'unrelated-copy.log').write_text('must not survive extraction')
            (self.result / 'lazy-database.sqlite').write_text('materialized')
        return b''

    def collect(self):
        return R.collect_native_observer(self.runner, self.folder, self.result, self.receipt)

    def test_exact_uuid_interval_pid_filter_and_only_session_retained(self):
        row = self.collect()
        self.assertTrue(row['complete'])
        calls = [call for call in self.commands if 'spawn' in call]
        self.assertTrue(all(call[3] == self.device['deviceId'] for call in calls))
        self.assertIn('processID == 10', calls[1][-1])
        self.assertIn('2026-10-25 05:00:00+0000', calls[0])
        self.assertFalse((self.folder / 'native-observer/offline-export').exists())
        self.assertTrue((self.folder / 'native-observer/xctest-session.log').exists())

    def test_sdk_predicate_matches_retained_native_product_event_identities(self):
        # Producer40146062194/job121033727125, app-commerce-filtered.log47-48.
        # Sanitized identities only; product response payload is not a fixture.
        retained = [dict(timestamp='2026-10-25 05:00:10.000000+0000', processID=25746, subsystem='com.apple.storekit'),
                    dict(timestamp='2026-10-25 05:00:10.000000+0000', processID=25746, subsystem='com.apple.storekit'),
                    dict(timestamp='2026-10-25 05:00:10.000000+0000', processID=25747, subsystem='com.apple.storekit')]
        for event in self.events:
            event['processID'] = 25746
            row = json.loads(event['eventMessage'][len(R.OBSERVER_PREFIX):]); row['pid'] = 25746
            event['eventMessage'] = R.OBSERVER_PREFIX + json.dumps(row)
        original = self.command
        def observed(folder, label, argv, deadline, export=None):
            if label == 'app-sdk':
                predicate = argv[-1]
                subsystems = R.re.findall(r'subsystem == "([^"]+)"', predicate)
                pid = int(R.re.search(r'processID == (\d+)', predicate)[1])
                return json.dumps([event for event in retained if event['processID'] == pid
                                   and event['subsystem'] in subsystems]).encode()
            return original(folder, label, argv, deadline, export)
        with patch.object(R, 'observer_command', side_effect=observed):
            row = self.collect()
        self.assertEqual(row['sdkEventCount'], 2)

    def test_known_producer_export_shape_retains_bounded_session(self):
        # Retained producer diagnostics:345files,197059893bytes; session16551418bytes.
        original = self.command
        def known_shape(folder, label, argv, deadline, export=None):
            if label != 'session-export': return original(folder, label, argv, deadline, export)
            session = export / 'CodexBarIOSUITests-session/Session-producer.log'
            session.parent.mkdir(parents=True)
            with session.open('wb') as stream:
                stream.write(b'CodexBarIOSUITests-Runner[20:123] requesting app (pid:10)')
                stream.truncate(16551418)
            for index in range(344):
                with (export / f'other-{index:03}.dat').open('wb') as stream:
                    stream.truncate(197059893 - 16551418 if index == 0 else 0)
            R.observer_export_cap(export)
            return b''
        with patch.object(R, 'observer_command', side_effect=known_shape):
            row = self.collect()
        self.assertTrue(row['complete'])
        self.assertEqual((self.folder / 'native-observer/xctest-session.log').stat().st_size, 16551418)
        self.assertFalse((self.folder / 'native-observer/offline-export').exists())

    def test_session_retention_has_its_own_cap(self):
        with patch.dict(R.OBSERVER_LIMITS, sessionBytes=8), self.assertRaisesRegex(R.PhaseFailure, 'session byte cap'):
            self.collect()
        self.assertFalse((self.folder / 'native-observer/xctest-session.log').exists())
        self.assertFalse(E.read(self.folder / 'native-observer/receipt.json')['complete'])

    def test_supplied_ownership_in_separate_provisioning_directory(self):
        device = self.root / 'device'; device.mkdir()
        ownership = device / 'ownership.json'
        (self.root / 'ownership.json').rename(ownership)
        (self.root / 'native-use.json').rename(device / 'native-use.json')
        # Exposes the supported input path to the actual collector, not a copied receipt.
        self.runner = R.Runner(self.root, self.device, {}, self.tools, ownership=ownership)
        row = self.collect()
        self.assertTrue(row['complete'])
        self.assertFalse((self.runner.output / 'ownership.json').exists())

    def test_supplied_ownership_requires_claim_beside_receipt(self):
        device = self.root / 'device'; device.mkdir()
        ownership = device / 'ownership.json'
        (self.root / 'ownership.json').rename(ownership)
        self.runner = R.Runner(self.root, self.device, {}, self.tools, ownership=ownership)
        # The unrelated claim left in the execution directory must not be accepted.
        with self.assertRaises(R.PhaseFailure):
            self.collect()
        self.assertEqual(self.commands, [])

    def test_fractional_phase_uses_supported_log_dates_and_outward_query_bounds(self):
        self.receipt.update(started='2026-10-25T01:00:00.900000-04:00', ended='2026-10-25T01:01:00.100000-04:00')
        original = self.command
        def exact_parser(folder, label, argv, deadline, export=None):
            if label in ('app-trace', 'app-sdk'):
                from datetime import datetime
                for option in ('--start', '--end'):
                    datetime.strptime(argv[argv.index(option)+1], '%Y-%m-%d %H:%M:%S%z')
            return original(folder, label, argv, deadline, export)
        with patch.object(R, 'observer_command', side_effect=exact_parser):
            row = self.collect()
        self.assertTrue(row['complete'])
        argv = next(c for c in self.commands if 'spawn' in c)
        self.assertIn('2026-10-25 05:00:00+0000', argv)
        self.assertIn('2026-10-25 05:01:01+0000', argv)

    def test_outward_query_does_not_admit_records_outside_exact_phase(self):
        self.receipt.update(started='2026-10-25T01:00:00.900000-04:00', ended='2026-10-25T01:01:00.100000-04:00')
        outside = dict(self.events[0], timestamp='2026-10-25 05:00:00.100000+0000')
        row = json.loads(outside['eventMessage'][len(R.OBSERVER_PREFIX):]); row['run'] = '10000000-0000-0000-0000-000000000099'
        outside['eventMessage'] = R.OBSERVER_PREFIX + json.dumps(row)
        self.events.insert(0, outside)
        original = self.command
        def sdk_edges(folder, label, argv, deadline, export=None):
            if label == 'app-sdk':
                return json.dumps([dict(timestamp=stamp) for stamp in ['2026-10-25 05:00:00.100000+0000',
                      '2026-10-25 05:00:10.000000+0000', '2026-10-25 05:01:00.900000+0000']]).encode()
            return original(folder, label, argv, deadline, export)
        with patch.object(R, 'observer_command', side_effect=sdk_edges):
            row = self.collect()
        self.assertEqual(len(row['app']), 5)
        self.assertEqual(row['sdkEventCount'], 1)

    def test_missing_runner_boundary_never_qualifies(self):
        self.records.pop(); self.write_runner()
        with self.assertRaisesRegex(R.PhaseFailure, 'boundary'):
            self.collect()

    def test_missing_app_trace_does_not_qualify_passing_xctest(self):
        self.events = []
        with self.assertRaisesRegex(R.PhaseFailure, 'Missing'):
            self.collect()
        self.assertFalse(E.read(self.folder / 'native-observer/receipt.json')['complete'])

    def test_mismatched_app_pid_or_run_id_fails_closed(self):
        self.events[0]['processID'] = 11
        with self.assertRaisesRegex(R.PhaseFailure, 'identity'):
            self.collect()

    def test_wrong_ownership_prevents_collection(self):
        row = E.read(self.root / 'ownership.json'); row['owner'] = '/another/checkout'; E.write(self.root / 'ownership.json', row)
        with self.assertRaisesRegex(R.PhaseFailure, 'ownership'):
            self.collect()
        self.assertEqual(self.commands, [])

    def test_log_parse_failure_and_export_failure_remain_visible(self):
        original = self.command
        def bad(folder, label, argv, deadline, export=None):
            return b'{invalid' if label == 'app-trace' else original(folder, label, argv, deadline, export)
        with patch.object(R, 'observer_command', side_effect=bad), self.assertRaises(R.PhaseFailure):
            self.collect()
        self.assertFalse(E.read(self.folder / 'native-observer/receipt.json')['complete'])

    def test_wrong_json_shape_is_recorded_as_parse_failure(self):
        self.events = [42]
        with self.assertRaisesRegex(R.PhaseFailure, 'shape'):
            self.collect()
        self.assertFalse(E.read(self.folder / 'native-observer/receipt.json')['complete'])

    def test_nonfinite_clock_fails_closed(self):
        self.records[0]['uptime'] = float('nan'); self.write_runner()
        with self.assertRaisesRegex(R.PhaseFailure, 'clock'):
            self.collect()

    def test_passing_run_missing_positive_callback_cannot_qualify(self):
        self.records = [r for r in self.records if r['stage'] != 'predicatePositive']; self.write_runner()
        with self.assertRaisesRegex(R.PhaseFailure, 'required app observations'):
            self.collect()

    def test_session_pid_prefix_is_not_exact_app_identity(self):
        original = self.command
        def other_pid(folder, label, argv, deadline, export=None):
            answer = original(folder, label, argv, deadline, export)
            if label == 'session-export':
                (export / 'CodexBarIOSUITests-session/Session-test.log').write_text('CodexBarIOSUITests-Runner[20:123] app pid:100')
            return answer
        with patch.object(R, 'observer_command', side_effect=other_pid), self.assertRaisesRegex(R.PhaseFailure, 'PIDs'):
            self.collect()

    def test_offline_export_failure_is_not_success(self):
        original = self.command
        def bad(folder, label, argv, deadline, export=None):
            if label == 'session-export': raise R.PhaseFailure('offline export unavailable')
            return original(folder, label, argv, deadline, export)
        with patch.object(R, 'observer_command', side_effect=bad), self.assertRaisesRegex(R.PhaseFailure, 'export unavailable'):
            self.collect()

    def test_observer_report_write_failure_is_required(self):
        with patch.object(R, 'write', side_effect=OSError('evidence volume full')), self.assertRaises(R.PhaseFailure):
            self.collect()


class BoundedProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def test_success_and_partial_output_cap(self):
        R.observer_command(self.folder, 'ok', [sys.executable, '-c', 'print("bounded")'], time.monotonic() + 5)
        with patch.dict(R.OBSERVER_LIMITS, stdoutBytes=128), self.assertRaisesRegex(R.PhaseFailure, 'byte cap'):
            R.observer_command(self.folder, 'large', [sys.executable, '-c', 'print("x"*10000)'], time.monotonic()+5)
        self.assertLessEqual((self.folder / 'large.stdout').stat().st_size, 128)
        self.assertFalse(E.read(self.folder / 'large.json')['complete'])
        self.assertTrue(E.read(self.folder / 'large.json')['truncated'])

    def test_deadline_terminates_owned_child_group(self):
        code = 'import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(20)"]); print(p.pid,flush=True); time.sleep(20)'
        with patch.dict(R.OBSERVER_LIMITS, commandSeconds=0.15), self.assertRaisesRegex(R.PhaseFailure, 'deadline'):
            R.observer_command(self.folder, 'timeout', [sys.executable, '-c', code], time.monotonic()+5)
        self.assertTrue(E.read(self.folder / 'timeout.json')['timedOut'])
        pid = int((self.folder / 'timeout.stdout').read_text())
        # A killed child can briefly be a zombie awaiting reaping, but cannot remain running.
        status = R.subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not status or status.startswith('Z'), status)

    def test_export_cap_also_checks_fast_completed_command(self):
        export = self.folder / 'export'
        export.mkdir()
        code = 'from pathlib import Path; Path(' + repr(str(export / 'large')) + ').write_bytes(b"x"*1024)'
        with patch.dict(R.OBSERVER_LIMITS, exportBytes=128), self.assertRaisesRegex(R.PhaseFailure, 'export byte/file cap'):
            R.observer_command(self.folder, 'export', [sys.executable, '-c', code], time.monotonic()+5, export)

    def test_output_write_failure_is_a_failure(self):
        original = Path.write_bytes
        def denied(path, data):
            if path.suffix == '.stdout': raise OSError('output volume full')
            return original(path, data)
        with patch.object(Path, 'write_bytes', denied), self.assertRaisesRegex(R.PhaseFailure, 'write failed'):
            R.observer_command(self.folder, 'write', [sys.executable, '-c', 'print(1)'], time.monotonic()+5)

class FakeObserverPipe:
    def __init__(self, process, name, data):
        self.process, self.name, self.data = process, name, data

    def close(self):
        self.process.events.append('close-' + self.name)
        if self.name in self.process.close_errors:
            raise OSError(self.name + ' close fault')


class FakeObserverProcess:
    """Retained fake Popen handle. No real PID or OS process is created."""
    pid = 424242

    def __init__(self, final_wait_error=None, close_errors=(), run_exit=0):
        self.events, self.waits = [], []
        self.final_wait_error, self.close_errors, self.run_exit = final_wait_error, close_errors, run_exit
        self.returncode = None
        self.stdout = FakeObserverPipe(self, 'stdout', b'partial stdout\n')
        self.stderr = FakeObserverPipe(self, 'stderr', b'partial stderr\n')

    def wait(self, timeout):
        self.waits.append(timeout)
        self.events.append('wait-run' if len(self.waits) == 1 else 'wait-cleanup')
        if len(self.waits) > 1 and self.final_wait_error:
            raise self.final_wait_error
        self.returncode = self.run_exit
        return self.returncode


class FakeObserverSelector:
    def __enter__(self): return self
    def __exit__(self, *_): return None
    def register(self, pipe, _event, data): data.extend(pipe.data)
    def get_map(self): return {}


@contextmanager
def fake_observer_os(process, kill_error=None):
    def kill(pid, signal):
        if pid != process.pid:
            raise AssertionError('Cleanup used an unowned PID')
        process.events.append('kill-owned-group')
        if kill_error:
            raise kill_error
    with patch.object(R.subprocess, 'Popen', return_value=process), \
            patch.object(R.selectors, 'DefaultSelector', return_value=FakeObserverSelector()), \
            patch.object(R.os, 'killpg', side_effect=kill):
        yield


class ObserverCleanupFaultTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def invoke(self, process, kill_error=None):
        with fake_observer_os(process, kill_error):
            return R.observer_command(self.folder, 'fault', ['fake-owned-command'], time.monotonic()+5)

    def assert_evidence_and_finite_cleanup(self, process):
        self.assertEqual(process.events[-4:], ['kill-owned-group', 'wait-cleanup', 'close-stdout', 'close-stderr'])
        self.assertEqual(len(process.waits), 2)
        self.assertEqual(process.waits[-1], 2)
        self.assertEqual((self.folder / 'fault.stdout').read_bytes(), b'partial stdout\n')
        self.assertEqual((self.folder / 'fault.stderr').read_bytes(), b'partial stderr\n')
        row = E.read(self.folder / 'fault.json')
        self.assertFalse(row['complete'])
        return row

    def test_final_wait_timeout_is_phase_failure_and_still_closes_both_pipes(self):
        process = FakeObserverProcess(final_wait_error=R.subprocess.TimeoutExpired('fake-owned-command', 2))
        with self.assertRaises(R.PhaseFailure): self.invoke(process)
        row = self.assert_evidence_and_finite_cleanup(process)
        self.assertEqual([e['step'] for e in row['cleanupErrors']], ['wait'])
        self.assertIn('timed out', row['cleanupErrors'][0]['error'])

    def test_run_error_remains_primary_with_all_cleanup_faults_visible(self):
        process = FakeObserverProcess(final_wait_error=R.subprocess.TimeoutExpired('fake-owned-command', 2),
                                      close_errors=('stdout', 'stderr'), run_exit=7)
        with self.assertRaises(R.PhaseFailure) as caught: self.invoke(process, OSError('kill fault'))
        row = self.assert_evidence_and_finite_cleanup(process)
        self.assertEqual(row['error'], 'Observer command exited 7')
        self.assertEqual([e['step'] for e in row['cleanupErrors']], ['kill', 'wait', 'stdout', 'stderr'])
        self.assertIn('exited 7', str(caught.exception))
        self.assertIn('kill fault', str(caught.exception))
        self.assertIn('stderr close fault', str(caught.exception))

    def test_pipe_close_oserror_attempts_other_pipe_and_fails_successful_command(self):
        process = FakeObserverProcess(close_errors=('stdout',))
        with self.assertRaises(R.PhaseFailure): self.invoke(process)
        row = self.assert_evidence_and_finite_cleanup(process)
        self.assertEqual([e['step'] for e in row['cleanupErrors']], ['stdout'])

    def test_kill_oserror_still_attempts_final_wait_and_pipe_closes(self):
        process = FakeObserverProcess()
        with self.assertRaises(R.PhaseFailure): self.invoke(process, OSError('kill fault'))
        row = self.assert_evidence_and_finite_cleanup(process)
        self.assertEqual([e['step'] for e in row['cleanupErrors']], ['kill'])

    def test_final_wait_oserror_still_attempts_both_pipe_closes(self):
        process = FakeObserverProcess(final_wait_error=OSError('wait fault'))
        with self.assertRaises(R.PhaseFailure): self.invoke(process)
        row = self.assert_evidence_and_finite_cleanup(process)
        self.assertEqual([e['step'] for e in row['cleanupErrors']], ['wait'])

    def test_absent_owned_group_is_benign(self):
        process = FakeObserverProcess()
        self.assertEqual(self.invoke(process, ProcessLookupError('already gone')), b'partial stdout\n')
        self.assertTrue(E.read(self.folder / 'fault.json')['complete'])

    def test_output_write_fault_still_saves_other_stream_and_command_receipt(self):
        process = FakeObserverProcess()
        original = Path.write_bytes
        def denied(path, data):
            if path.name == 'fault.stdout': raise OSError('stdout volume fault')
            return original(path, data)
        with patch.object(Path, 'write_bytes', denied), self.assertRaises(R.PhaseFailure): self.invoke(process)
        self.assertEqual((self.folder / 'fault.stderr').read_bytes(), b'partial stderr\n')
        row = E.read(self.folder / 'fault.json')
        self.assertFalse(row['complete'])
        self.assertEqual(row['writeErrors'][0]['stream'], 'stdout')
        self.assertEqual(process.events[-2:], ['close-stdout', 'close-stderr'])


class ObserverCleanupPhaseTests(unittest.TestCase):
    setUp = NativePhaseFlowTests.setUp
    """Only these two new controls, not the inherited cases, belong to the cleanup proof."""
    def cleanup_case(self, native_exit, reset_exit):
        self.f.exit_codes.update({'ui-native': native_exit, 'ui-reset': reset_exit})
        self.runner.tools = {'developer_dir': '/Applications/Qualified.app/Contents/Developer'}
        self.f.device.update(deviceName='CodexBar 470 ipad fake', runtimeBundlePath='/qualified/runtime',
                             deviceId='10000000-0000-0000-0000-000000000001')
        build = E.read(self.f.build); build.update(tools=self.runner.tools, device=self.f.device); E.write(self.f.build, build)
        E.write(self.f.root / 'ownership.json', dict(owner=str(R.ROOT), tools=self.runner.tools, device=self.f.device,
                created=dict(exit=0, command=['xcrun', 'simctl', 'create', self.f.device['deviceName'], 'type', '/qualified/runtime'])))
        E.write(self.f.root / 'native-use.json', dict(deviceId=self.f.device['deviceId'], output=str(self.f.root)))
        process = FakeObserverProcess(final_wait_error=R.subprocess.TimeoutExpired('fake-owned-command', 2))
        original_fixture = FIXTURE.result_fixture
        def matching_device(identities):
            summary, tree, _ = original_fixture(identities)
            summary['devicesAndConfigurations'][0]['device'] = self.f.device
            tree['devices'] = [self.f.device]
            return summary, tree, self.f.device
        # Actual collector and observer_command are both executed. Only OS handles/tools are fake.
        with patch.object(R, 'require_pinned'), patch.dict(os.environ, {'DEVELOPER_DIR': self.runner.tools['developer_dir']}), \
                patch.object(FIXTURE, 'result_fixture', side_effect=matching_device), fake_observer_os(process):
            state = R.sequence(['ui-native'], lambda name: self.runner.phase(name, self.f.build),
                               lambda: self.runner.phase('ui-reset', self.f.build))
        with patch.object(R, 'toolchain', return_value={}): R.shutdown(self.f.root, self.f.device)
        phase = E.read(self.f.root / 'ui-native/receipt.json')
        capture = E.read(self.f.root / 'ui-native/native-observer/receipt.json')
        command = E.read(self.f.root / 'ui-native/native-observer/find-simctl.json')
        self.assertFalse(capture['complete']); self.assertFalse(command['complete'])
        self.assertIn('timed out', phase['observerError'])
        self.assertEqual(command['cleanupErrors'][0]['step'], 'wait')
        self.assertEqual(len(process.waits), 2)
        self.assertEqual(process.events[-2:], ['close-stdout', 'close-stderr'])
        self.assertTrue(any(call[-2:] == ['shutdown', self.f.device['deviceId']] for call in self.f.calls))
        return state, phase

    def test_native65_cleanup_timeout_reset66_and_shutdown_preserve_all_evidence(self):
        state, phase = self.cleanup_case(65, 66)
        self.assertEqual(state['exit'], 65); self.assertEqual(phase['exit'], 65)
        self.assertIn('66', state['cleanupFailure'])

    def test_passing_xctest_cleanup_timeout_fails_observer_and_preserves_reset(self):
        state, phase = self.cleanup_case(0, 0)
        self.assertEqual(state['exit'], 1); self.assertEqual(phase['exit'], 1)
        self.assertIsNone(state['cleanupFailure'])
        self.assertNotIn('validationError', phase)



if __name__ == '__main__':
    unittest.main()
