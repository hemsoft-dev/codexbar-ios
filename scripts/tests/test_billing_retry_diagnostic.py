"""Manual-only orchestration controls; no Swift, simulator, account or network execution."""
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / 'tests'))
import test_ci_policy as ci_policy

spec = importlib.util.spec_from_file_location('billing_diagnostic', SCRIPTS / 'run-billing-retry-diagnostic.py')
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)


def fixture(status='Passed', identities=None):
    identities = identities if identities is not None else [D.SELECTOR]
    timestamp = datetime.now(timezone.utc).timestamp()
    device = dict(deviceId='owned-fixture', modelName='iPhone Air', osVersion='26.2',
                  osBuildNumber='23C54', architecture='arm64', platform='iOS Simulator', family='iphone')
    failed = status == 'Failed'
    counts = dict(passedTests=0 if failed else len(identities), failedTests=1 if failed else 0,
                  skippedTests=0, expectedFailures=0)
    summary = dict(result=status, totalTestCount=len(identities), **counts,
                   startTime=timestamp, finishTime=timestamp,
                   testFailures=[{'failureText': 'fixture manual retry assertion'}] if failed else [],
                   devicesAndConfigurations=[dict(device=device, **counts)])
    nodes = [dict(nodeType='Test Case', nodeIdentifier='/'.join(x.split('/')[1:])+'()',
                  nodeIdentifierURL='test://com.apple.xcode/CodexBarIOS/'+x, result=status)
             for x in identities]
    tree = dict(devices=[device], testNodes=[dict(nodeType='Unit test bundle', name='CodexBarIOSTests', children=nodes)])
    return summary, tree, device


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / 'diagnostic'
        self.output.mkdir()
        self.summary, self.tree, self.device = fixture()
        self.source, self.tools = {'revision': 'fixture', 'status': ''}, {'fixture': 'tools'}
        self.runner = D.project.Runner(self.output, self.device, self.source, self.tools)
        self.binary = self.root / 'signed-binary-fixture'
        self.binary.write_bytes(b'fixture binary, not an Apple build')
        self.config = self.output / 'DerivedData-billing-retry/Build/Products/CodexBarIOS_fixture.xctestrun'
        self.binary_records = patch.object(D.project, 'binaries', side_effect=self.binaries).start()
        self.statuses, self.calls, self.executions = ['Passed'] * 3, [], 0
        self.export_error = False
        self.addCleanup(patch.stopall)
        patch.object(D.project.Runner, 'unchanged').start()
        patch.object(D.project, 'command', side_effect=self.command).start()
        self.shutdown = patch.object(D.project, 'shutdown').start()

    def binaries(self, derived, signed):
        self.config = derived / 'Build/Products/CodexBarIOS_fixture.xctestrun'
        self.config.parent.mkdir(parents=True)
        self.config.write_bytes(b'fixture configuration, not an Apple build')
        return [dict(path=str(self.binary), kind='.app', sha256=D.evidence.digest(self.binary)),
                dict(path=str(self.config), kind='.xctestrun', sha256=D.evidence.digest(self.config))]

    def command(self, output, name, argv):
        """Mock only OS/Xcode transport; execute the real Python orchestration."""
        self.calls.append(argv)
        record = dict(command=argv, started=D.evidence.now(), ended=D.evidence.now(), exit=0)
        text = ''
        if '-enumerate-tests' in argv:
            enumeration = dict(errors=[], values=[dict(testPlan='Fixture',
                enabledTests=[dict(identifier=D.SELECTOR+'()')], disabledTests=[])])
            Path(argv[argv.index('-test-enumeration-output-path')+1]).write_text(json.dumps(enumeration))
        elif argv[-1] == 'test-without-building':
            status = self.statuses[self.executions]
            self.executions += 1
            if status == 'host-error':
                (output / (name+'.log')).write_text('fixture runner error')
                raise D.project.PhaseFailure('fixture test host exited', 70)
            self.summary, self.tree, _ = fixture(status)
            if status == 'Failed':
                (output / (name+'.log')).write_text('[DEBUG-ios573] fixture operands\n')
                raise D.project.PhaseFailure('fixture XCTest assertion exit', 65)
        elif argv[:3] == ['xcrun', 'xcresulttool', 'get']:
            if self.export_error:
                raise D.project.PhaseFailure('fixture exporter exited', 74)
            text = json.dumps(self.summary if argv[4] == 'summary' else self.tree)
        (output / (name+'.log')).write_text(text)
        D.evidence.write(output / (name+'.command.json'), record)
        return record

    def test_build_once_exact_signed_serial_selector_for_three_measurements(self):
        self.assertEqual(D.SELECTOR, 'CodexBarIOSTests/SubscriptionBillingTests/'
                         'testFailedCredentialHasFiniteAutomaticBudgetAndManualRetry')
        D.experiment(self.runner, 3)
        builds = [x for x in self.calls if x[-1] == 'build-for-testing']
        tests = [x for x in self.calls if x[-1] == 'test-without-building']
        self.assertEqual((len(builds), len(tests), self.executions), (1, 3, 3))
        discoveries = [x for x in self.calls if '-enumerate-tests' in x]
        self.assertEqual(len(discoveries), 1)
        for argv in tests + discoveries:
            self.assertEqual(argv[argv.index('-xctestrun')+1], str(self.config))
            self.assertNotIn('-project', argv)
            self.assertNotIn('-scheme', argv)
        for argv in builds + tests + [x for x in self.calls if '-enumerate-tests' in x]:
            self.assertEqual([x for x in argv if x.startswith('-only-testing:')], ['-only-testing:'+D.SELECTOR])
            self.assertIn('CODE_SIGNING_ALLOWED=YES', argv)
            self.assertIn('CODE_SIGN_IDENTITY=-', argv)
            self.assertEqual(argv[argv.index('-parallel-testing-enabled')+1], 'NO')
            self.assertEqual(argv[argv.index('-maximum-concurrent-test-simulator-destinations')+1], '1')
        self.assertEqual(len(list(self.output.glob('attempt-*/diagnostic.json'))), 3)
        discovery = D.evidence.read(self.output / 'discovery-input.json')
        for number in range(1, 4):
            attempt = D.evidence.read(self.output / f'attempt-{number}/diagnostic.json')
            self.assertEqual(attempt['testConfiguration'], discovery['testConfiguration'])
            self.assertEqual(attempt['build_sha256'], discovery['build_sha256'])

    def test_first_red_is_retained_and_no_third_attempt_can_hide_it(self):
        self.statuses = ['Passed', 'Failed', 'Passed']
        with self.assertRaises(D.project.PhaseFailure) as caught:
            D.experiment(self.runner, 3)
        self.assertEqual(caught.exception.code, 65)
        self.assertEqual(self.executions, 2)
        receipt = D.evidence.read(self.output / 'attempt-2/diagnostic.json')
        self.assertEqual((receipt['exit'], receipt['verdict'], receipt['testResult']), (65, 'test-failure', 'Failed'))
        self.assertEqual(receipt['operandTraceLines'], 1)
        self.assertFalse((self.output / 'attempt-3').exists())

    def test_invalid_recorded_configuration_never_starts_discovery_or_tests(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        original = D.evidence.read(build)
        outside = self.root / 'foreign.xctestrun'
        outside.write_bytes(self.config.read_bytes())
        cases = [([], 'missing'),
                 ([dict(original['binaries'][-1]), dict(original['binaries'][-1])], 'ambiguous'),
                 ([dict(original['binaries'][-1], kind='.app')], 'wrong kind'),
                 ([dict(original['binaries'][-1], path=str(outside))], 'outside'),
                 ([dict(original['binaries'][-1], path=str(self.config.with_suffix('.json')))], 'suffix'),
                 ([dict(original['binaries'][-1], path=str(self.config.parent / 'absent.xctestrun'))], 'absent'),
                 ([dict(original['binaries'][-1], path=str(self.config.parent))], 'directory'),
                 ([dict(original['binaries'][-1], path=str(self.config.parent / '..' / 'Products' / self.config.name))], 'traversal')]
        for entries, label in cases:
            with self.subTest(label=label):
                record = dict(original, binaries=[original['binaries'][0]] + entries)
                D.evidence.write(build, record)
                self.calls.clear()
                with patch.object(self.runner, 'build', return_value=build), self.assertRaises(ValueError):
                    D.experiment(self.runner, 1)
                self.assertEqual(self.calls, [])
                self.assertEqual(self.executions, 0)

    def test_configuration_symlink_is_rejected_before_discovery(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        self.calls.clear()
        # Mock the OS report so this control also runs on hosts without symlink privileges.
        with patch.object(Path, 'is_symlink', autospec=True, side_effect=lambda path: path == self.config), \
             patch.object(self.runner, 'build', return_value=build), self.assertRaisesRegex(ValueError, 'symlinks'):
            D.experiment(self.runner, 1)
        self.assertEqual(self.calls, [])

    def test_configuration_parent_symlink_is_rejected_before_discovery(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        products = self.config.parent
        self.calls.clear()
        with patch.object(Path, 'is_symlink', autospec=True, side_effect=lambda path: path == products), \
             patch.object(self.runner, 'build', return_value=build), self.assertRaisesRegex(ValueError, 'symlinks'):
            D.experiment(self.runner, 1)
        self.assertEqual(self.calls, [])

    def test_configuration_tamper_before_discovery_is_rejected(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        self.config.write_bytes(b'changed configuration')
        self.calls.clear()
        with patch.object(self.runner, 'build', return_value=build), self.assertRaisesRegex(ValueError, 'binaries changed'):
            D.experiment(self.runner, 1)
        self.assertEqual(self.calls, [])

    def test_configuration_changed_between_discovery_and_attempt_stops_execution(self):
        original = self.command
        def command(output, name, argv):
            record = original(output, name, argv)
            if '-enumerate-tests' in argv:
                self.config.write_bytes(b'changed after discovery')
            return record
        with patch.object(D.project, 'command', side_effect=command), self.assertRaises(D.project.PhaseFailure):
            D.experiment(self.runner, 3)
        self.assertEqual(self.executions, 0)
        receipt = D.evidence.read(self.output / 'attempt-1/diagnostic.json')
        self.assertEqual((receipt['exit'], receipt['verdict']), (1, 'execution-failure'))
        self.assertFalse((self.output / 'attempt-2').exists())

    def test_build_receipt_change_after_discovery_is_rejected_even_with_new_hash(self):
        original = self.command
        def command(output, name, argv):
            record = original(output, name, argv)
            if '-enumerate-tests' in argv:
                self.config.write_bytes(b'changed configuration and receipt')
                path = self.output / 'build-billing-retry.json'
                build = D.evidence.read(path)
                build['binaries'][-1]['sha256'] = D.evidence.digest(self.config)
                D.evidence.write(path, build)
            return record
        with patch.object(D.project, 'command', side_effect=command), self.assertRaises(D.project.PhaseFailure):
            D.experiment(self.runner, 1)
        self.assertEqual(self.executions, 0)
        self.assertIn('after discovery', D.evidence.read(self.output / 'attempt-1/diagnostic.json')['error'])

    def test_binary_change_after_discovery_is_rejected(self):
        original = self.command
        def command(output, name, argv):
            record = original(output, name, argv)
            if '-enumerate-tests' in argv:
                self.binary.write_bytes(b'changed executable')
            return record
        with patch.object(D.project, 'command', side_effect=command), self.assertRaises(D.project.PhaseFailure):
            D.experiment(self.runner, 1)
        self.assertEqual(self.executions, 0)

    def test_build_device_mismatch_is_rejected_before_discovery(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        record = D.evidence.read(build)
        record['device']['deviceId'] = 'foreign-device'
        D.evidence.write(build, record)
        self.calls.clear()
        with patch.object(self.runner, 'build', return_value=build), self.assertRaisesRegex(ValueError, 'device mismatch'):
            D.experiment(self.runner, 1)
        self.assertEqual(self.calls, [])

    def test_build_identity_and_configuration_mismatches_stop_before_discovery(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        original = D.evidence.read(build)
        for field, value in [('source', {'revision': 'other'}), ('tools', {'fixture': 'other'}),
                             ('exit', 65), ('scheme', 'Other'), ('configuration', 'Release'),
                             ('coverage', False), ('derivedData', str(self.root / 'foreign-derived'))]:
            with self.subTest(field=field):
                D.evidence.write(build, dict(original, **{field: value}))
                self.calls.clear()
                with patch.object(self.runner, 'build', return_value=build), self.assertRaises(ValueError):
                    D.experiment(self.runner, 1)
                self.assertEqual(self.calls, [])
                self.assertEqual(self.executions, 0)

    def test_wrong_discovery_does_not_start_an_attempt(self):
        original = self.command
        def command(output, name, argv):
            record = original(output, name, argv)
            if '-enumerate-tests' in argv:
                D.evidence.write(self.output / 'discovery.json', dict(errors=[], values=[dict(
                    testPlan='Fixture', enabledTests=[dict(identifier='CodexBarIOSTests/OtherTests/testOther')],
                    disabledTests=[])]))
            return record
        with patch.object(D.project, 'command', side_effect=command), self.assertRaisesRegex(ValueError, 'discovery differs'):
            D.experiment(self.runner, 1)
        self.assertEqual(self.executions, 0)

    def test_non_test_error_and_export_error_preserve_first_exit(self):
        self.statuses, self.export_error = ['host-error'], True
        with self.assertRaises(D.project.PhaseFailure) as caught:
            D.experiment(self.runner, 3)
        self.assertEqual(caught.exception.code, 70)
        receipt = D.evidence.read(self.output / 'attempt-1/diagnostic.json')
        self.assertEqual(receipt['verdict'], 'execution-failure')
        self.assertIn('summaryError', receipt)
        self.assertIn('testsError', receipt)
        self.assertEqual(self.executions, 1)

    def test_build_failure_executes_no_tests(self):
        with patch.object(self.runner, 'build', side_effect=D.project.PhaseFailure('compile failed', 66)):
            with self.assertRaises(D.project.PhaseFailure) as caught:
                D.experiment(self.runner, 3)
        self.assertEqual(caught.exception.code, 66)
        self.assertEqual(self.executions, 0)

    def test_source_change_after_passing_case_records_execution_failure(self):
        build = self.runner.build('billing-retry', 'CodexBarIOS', [D.SELECTOR])
        with patch.object(self.runner, 'unchanged', side_effect=[None, ValueError('fixture source changed')]):
            with self.assertRaises(D.project.PhaseFailure):
                D.attempt(self.runner, build, 1)
        receipt = D.evidence.read(self.output / 'attempt-1/diagnostic.json')
        self.assertEqual((receipt['exit'], receipt['verdict'], receipt['testResult']),
                         (1, 'execution-failure', 'Passed'))
        self.assertIn('fixture source changed', receipt['error'])

    def test_trace_write_after_passing_case_stops_experiment_as_execution_failure(self):
        original = Path.write_text
        def write_text(path, *args, **kwargs):
            if path.name == 'operand-trace.log':
                raise OSError('fixture trace write failed')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'write_text', new=write_text):
            with self.assertRaises(D.project.PhaseFailure):
                D.experiment(self.runner, 3)
        receipt = D.evidence.read(self.output / 'attempt-1/diagnostic.json')
        self.assertEqual((receipt['exit'], receipt['verdict'], receipt['testResult']),
                         (1, 'execution-failure', 'Passed'))
        self.assertEqual(self.executions, 1)

    def test_attempt_bounds_rejected_before_build(self):
        for value in (0, 4, -1, True, '3'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                D.experiment(self.runner, value)
        self.assertEqual(self.calls, [])

    def test_missing_extra_substituted_skipped_and_repeated_results_rejected(self):
        now = D.evidence.now()
        for identities in ([], [D.SELECTOR, 'CodexBarIOSTests/OtherTests/testExtra'],
                           ['CodexBarIOSTests/OtherTests/testOther'], [D.SELECTOR, D.SELECTOR]):
            summary, tree, device = fixture(identities=identities)
            with self.subTest(identities=identities), self.assertRaises(ValueError):
                D.validate_result(summary, tree, device, now, D.evidence.now())
        summary, tree, device = fixture('Skipped')
        with self.assertRaises(ValueError):
            D.validate_result(summary, tree, device, now, D.evidence.now())
        summary, tree, device = fixture()
        tree['testNodes'][0]['children'][0]['children'] = [dict(nodeType='Test Case Run')]
        with self.assertRaises(ValueError):
            D.validate_result(summary, tree, device, now, D.evidence.now())

    def test_receipt_failure_does_not_replace_xctest_exit(self):
        self.statuses = ['Failed']
        original = D.project.persist
        def persist(path, value, primary=None):
            if path.name == 'diagnostic.json':
                with patch.object(D.project, 'write', side_effect=OSError('fixture volume unavailable')):
                    return original(path, value, primary)
            return original(path, value, primary)
        with patch.object(D.project, 'persist', side_effect=persist):
            with self.assertRaises(D.project.PhaseFailure) as caught:
                D.experiment(self.runner, 3)
        self.assertEqual(caught.exception.code, 65)
        self.assertEqual(self.executions, 1)

    def test_invalid_failed_result_is_not_accepted_as_targeted_red(self):
        now = D.evidence.now()
        for mutate in (lambda s, t: s.update(failedTests=2),
                       lambda s, t: s.update(testFailures=[]),
                       lambda s, t: t['devices'][0].update(deviceId='foreign-device')):
            summary, tree, device = fixture('Failed')
            # Keep expected destination independent of the mutable exported fixture.
            device = dict(device)
            mutate(summary, tree)
            with self.assertRaises(ValueError):
                D.validate_result(summary, tree, device, now, D.evidence.now())

    def test_main_default_one_and_failure_quarantines_claimed_destination(self):
        ownership = self.root / 'device/ownership.json'
        ownership.parent.mkdir()
        ownership.write_text('{}')
        self.statuses = ['Failed']
        destination = self.root / 'main-output'
        with patch.object(D.evidence, 'source_snapshot', return_value=self.source), \
             patch.object(D.evidence, 'toolchain', return_value=self.tools), \
             patch.object(D.project, 'owned_device', return_value=self.device), \
             patch.object(D.evidence, 'require_pinned'):
            self.assertEqual(D.main(['--output', str(destination), '--ownership', str(ownership)]), 65)
        outcome = D.evidence.read(destination / 'outcome.json')
        self.assertEqual((outcome['requestedAttempts'], outcome['attemptsRecorded']), (1, 1))
        self.assertFalse(outcome['experimentComplete'])
        self.assertFalse(outcome['deviceReusable'])
        self.assertTrue((destination / 'quarantine.json').exists())
        self.assertTrue((ownership.parent / 'native-use.json').exists())
        self.shutdown.assert_called_once_with(destination, self.device)
        with self.assertRaises(FileExistsError):
            D.main(['--output', str(destination), '--ownership', str(ownership)])
        with self.assertRaisesRegex(ValueError, 'already used'):
            D.project.owned_device(ownership, self.tools)

    def run_main_fixture(self, destination):
        ownership = self.root / (destination.name + '-device') / 'ownership.json'
        ownership.parent.mkdir()
        ownership.write_text('{}')
        with patch.object(D.evidence, 'source_snapshot', return_value=self.source), \
             patch.object(D.evidence, 'toolchain', return_value=self.tools), \
             patch.object(D.project, 'owned_device', return_value=self.device), \
             patch.object(D.evidence, 'require_pinned'):
            return D.main(['--output', str(destination), '--ownership', str(ownership)])

    def test_success_shuts_down_claimed_destination_before_completion(self):
        destination = self.root / 'success-output'
        self.assertEqual(self.run_main_fixture(destination), 0)
        self.shutdown.assert_called_once_with(destination, self.device)
        outcome = D.evidence.read(destination / 'outcome.json')
        self.assertTrue(outcome['experimentComplete'])
        self.assertEqual(outcome['exit'], 0)
        self.assertFalse(outcome['deviceReusable'])

    def test_shutdown_error_fails_success_and_preserves_first_test_failure(self):
        for status, expected in [('Passed', 71), ('Failed', 65)]:
            with self.subTest(status=status):
                self.statuses, self.executions = [status], 0
                self.shutdown.reset_mock()
                self.shutdown.side_effect = D.project.PhaseFailure('fixture shutdown failed', 71)
                destination = self.root / ('shutdown-' + status)
                self.assertEqual(self.run_main_fixture(destination), expected)
                self.shutdown.assert_called_once_with(destination, self.device)
                outcome = D.evidence.read(destination / 'outcome.json')
                self.assertEqual(outcome['exit'], expected)
                self.assertFalse(outcome['experimentComplete'])
                self.assertIn('fixture shutdown failed', outcome['shutdownFailure'])
                self.assertTrue((destination / 'quarantine.json').exists())

    def test_diagnostic_receipt_cannot_qualify_release_phase(self):
        receipt = D.diagnostic_record(exit=0, experimentComplete=True)
        self.assertFalse(receipt['qualifiesRelease'])
        with self.assertRaisesRegex(ValueError, 'Failed or incorrect phase receipt'):
            D.evidence.validate_receipt(receipt, self.source, self.tools, [D.SELECTOR], 'ios', self.root)

    def test_workflow_dispatch_only_and_automatic_ci_does_not_run_these_controls(self):
        workflow = (SCRIPTS.parent / '.github/workflows/billing-retry-diagnostic.yml').read_text()
        self.assertEqual(ci_policy.workflow_trigger_keys(workflow), {'workflow_dispatch'})
        self.assertEqual(workflow.count('    runs-on:'), 1)
        self.assertNotIn('matrix:', workflow)
        self.assertNotIn('ci.yml', workflow)
        self.assertNotIn('test_billing_retry_diagnostic', ci_policy.CI_WORKFLOW.read_text())
        self.assertIn("options: ['1', '2', '3']", workflow)
        self.assertIn("default: '1'", workflow)
        self.assertNotIn('run.sh', workflow)


if __name__ == '__main__':
    unittest.main()
