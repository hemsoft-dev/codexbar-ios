"""Manual-only release harness fixtures; no Xcode, simulator, or network work."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import release_evidence as EVIDENCE
import pro_release_runner as RUNNER


def discovery_fixture(identities, disabled=()):
    return dict(errors=[], values=[dict(testPlan='Fixture', enabledTests=[dict(identifier=test+'()') for test in identities],
                                       disabledTests=[dict(identifier=test+'()') for test in disabled])])


def result_fixture(identities):
    device = dict(deviceId='owned-device', modelName='iPhone 17', osVersion='26.2',
                  osBuildNumber='23C54', architecture='arm64', platform='iOS Simulator', family='iphone')
    summary = dict(result='Passed', totalTestCount=len(identities), passedTests=len(identities),
                   failedTests=0, skippedTests=0, expectedFailures=0, startTime=100, finishTime=101,
                   devicesAndConfigurations=[dict(device=device, passedTests=len(identities),
                                                  failedTests=0, skippedTests=0, expectedFailures=0)])
    cases = [dict(nodeType='Test Case', nodeIdentifier='/'.join(identity.split('/')[1:])+'()',
                  nodeIdentifierURL='test://com.apple.xcode/CodexBarIOS/'+identity, result='Passed')
             for identity in identities]
    tree = dict(devices=[device], testNodes=[dict(nodeType='Unit test bundle', name='CodexBarIOSTests', children=cases)])
    return summary, tree, device


class PhaseResultTests(unittest.TestCase):
    def setUp(self):
        self.expected = ['CodexBarIOSTests/ExampleTests/testFirst', 'CodexBarIOSTests/ExampleTests/testSecond']
        self.summary, self.tree, self.device = result_fixture(self.expected)

    def verify(self):
        return EVIDENCE.validate_results(self.summary, self.tree, self.expected, self.device)

    def test_exact_identity_and_counts_pass(self):
        self.assertEqual(self.verify(), self.expected)

    def test_same_count_substituted_method_fails(self):
        self.expected[1] = 'CodexBarIOSTests/ExampleTests/testOmitted'
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.verify()

    def test_empty_duplicate_skipped_failed_and_expected_failure_rejected(self):
        for key, value in [('totalTestCount', 0), ('passedTests', 1), ('skippedTests', 1),
                           ('failedTests', 1), ('expectedFailures', 1)]:
            with self.subTest(key=key), patch.dict(self.summary, {key: value}), self.assertRaises(ValueError):
                self.verify()
        cases = self.tree['testNodes'][0]['children']
        cases.append(copy.deepcopy(cases[0]))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.verify()
        cases.clear()
        with self.assertRaisesRegex(ValueError, 'Empty'):
            self.verify()

    def test_failure_child_cannot_hide_failed_test(self):
        case = self.tree['testNodes'][0]['children'][0]
        case.update(result='Failed', children=[dict(nodeType='Failure Message', name='setup failed')])
        with self.assertRaisesRegex(ValueError, 'Nonpassing tests'):
            self.verify()

    def test_repetitions_or_inconsistent_url_fail(self):
        case = self.tree['testNodes'][0]['children'][0]
        case['children'] = [dict(nodeType='Test Case Run', result='Passed')]
        with self.assertRaisesRegex(ValueError, 'Repeated'):
            self.verify()
        case.pop('children')
        case['nodeIdentifierURL'] = case['nodeIdentifierURL'].replace('ExampleTests', 'OtherTests')
        with self.assertRaisesRegex(ValueError, 'disagree'):
            self.verify()

    def test_wrong_device_runtime_and_family_fail(self):
        for key, value in [('deviceId', 'other'), ('osVersion', '27.0'), ('osBuildNumber', 'wrong'),
                           ('architecture', 'x86_64'), ('platform', 'watchOS Simulator'), ('family', 'ipad')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                EVIDENCE.validate_results(self.summary, self.tree, self.expected, dict(self.device, **{key: value}))

    def test_stale_result_timestamp_fails(self):
        with self.assertRaisesRegex(ValueError, 'predates'):
            EVIDENCE.validate_results(self.summary, self.tree, self.expected, started='2026-10-18T00:00:00+00:00')

    def test_flat_discovery_requires_exact_unique_method_identifiers(self):
        self.assertEqual(EVIDENCE.discovery_tests(discovery_fixture(self.expected)), self.expected)
        for value in ({'tests': []}, discovery_fixture(self.expected * 2), discovery_fixture(['ExampleTests'])):
            with self.assertRaises(ValueError):
                EVIDENCE.discovery_tests(value)

    def test_actual_xcode_flat_enumeration_excludes_disabled_method(self):
        actual = EVIDENCE.read(Path(__file__).parent / 'fixtures/xcode-27-flat-enumeration.json')
        self.assertEqual(EVIDENCE.discovery_tests(actual), ['UnionTests/UnionTests/testOrdinary'])
        actual['errors'] = ['enumeration failed']
        with self.assertRaisesRegex(ValueError, 'error-free'):
            EVIDENCE.discovery_tests(actual)


class PhaseManifestTests(unittest.TestCase):
    def test_explicit_partitions_match_current_source(self):
        manifest = EVIDENCE.load_manifest()
        discovered = set()
        for source in (EVIDENCE.ROOT / 'CodexBarIOSUITests').glob('*.swift'):
            text = source.read_text()
            classes = list(re.finditer(r'(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b', text))
            for index, match in enumerate(classes):
                end = classes[index+1].start() if index+1 < len(classes) else len(text)
                for method in re.findall(r'\bfunc\s+(test\w+)\s*\(\s*\)', text[match.end():end]):
                    discovered.add(f'CodexBarIOSUITests/{match[1]}/{method}')
        declared = set(manifest['excluded_marketing'])
        for name in manifest['ui_journeys']:
            declared.update(manifest['phases'][name]['tests'])
        self.assertEqual(discovered, declared)
        self.assertEqual(len(discovered), 52)
        self.assertEqual(len(manifest['shared_pro_tests']), 197)
        self.assertEqual(len(manifest['shared_pro_sources']), 22)

    def test_missing_or_duplicate_manifest_selectors_fail(self):
        manifest = EVIDENCE.load_manifest()
        phase = manifest['phases']['native-commerce']
        for tests in ([], phase['tests'][:-1], phase['tests'][:-1] + phase['tests'][:1]):
            altered = copy.deepcopy(manifest)
            altered['phases']['native-commerce']['tests'] = tests
            with patch.object(EVIDENCE, 'read', return_value=altered), self.assertRaises(ValueError):
                EVIDENCE.load_manifest()

    def test_marketing_is_never_a_release_journey(self):
        manifest = EVIDENCE.load_manifest()
        phase = manifest['phases']['ui-native']
        phase['tests'] = manifest['excluded_marketing']
        with patch.object(EVIDENCE, 'read', return_value=manifest), self.assertRaisesRegex(ValueError, 'Marketing'):
            EVIDENCE.load_manifest()

    def test_execution_schedule_cannot_omit_duplicate_or_reorder_phases(self):
        for key in ('ui_phases', 'native_phases', 'coverage_phases'):
            manifest = EVIDENCE.load_manifest()
            for replacement in (manifest[key][1:], manifest[key] * 2, list(reversed(manifest[key]))):
                with self.subTest(key=key, replacement=replacement):
                    altered = copy.deepcopy(manifest)
                    altered[key] = replacement
                    with patch.object(EVIDENCE, 'read', return_value=altered), self.assertRaises(ValueError):
                        EVIDENCE.load_manifest()


class RunnerCommandFailureTests(unittest.TestCase):
    """Exercise real phase/command/receipt flow with only OS process calls mocked."""
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.manifest = EVIDENCE.load_manifest()
        _, _, self.device = result_fixture(['CodexBarIOSTests/ExampleTests/testFirst'])
        self.runner = RUNNER.Runner(self.root, self.device, {}, {})
        self.build = self.root / 'build-native.json'
        EVIDENCE.write(self.build, dict(binaries=[], scheme='CodexBarProNativeCommerce', native=True,
                                       source={}, tools={}, exit=0, device=self.device, configuration='Debug', coverage=True,
                                       derivedData=str(self.root / 'DerivedData-native')))
        self.calls = []
        self.exit_codes = {}
        self.extraction_error = False
        self.lazy_result_database = False
        self.device_state = 'Booted'
        self.patches = [patch.object(self.runner, 'unchanged'),
                        patch.object(RUNNER.subprocess, 'run', side_effect=self.process),
                        patch.object(RUNNER, 'device_record', side_effect=lambda *_: dict(self.device, state=self.device_state))]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def storekit_restarts(self):
        restart = ['launchctl', 'stop', 'com.apple.storekitd']
        return ['restart' if call[-3:] == restart else 'discovery' if '-enumerate-tests' in call
                else 'test' if '-resultBundlePath' in call else None for call in self.calls]

    def test_native_phases_restart_storekitd_before_discovery_and_execution(self):
        self.runner.phase('native-preparation', self.build)
        order = [step for step in self.storekit_restarts() if step]
        self.assertEqual(order, ['restart', 'discovery', 'restart', 'test'])
        restart = next(call for call in self.calls if call[-1] == 'com.apple.storekitd')
        self.assertEqual(restart[:4], ['xcrun', 'simctl', 'spawn', self.device['deviceId']])
        for name in ('storekitd-before-discovery', 'storekitd-before-test'):
            self.assertEqual(EVIDENCE.read(self.root / f'native-preparation/{name}.command.json')['exit'], 0)

    def test_native_journeys_keep_their_preparation_storekit_state(self):
        # A restart before ui-native discarded ui-preparation's disableDialogs override (#502).
        try:
            self.runner.phase('ui-native', self.build)
        except RUNNER.PhaseFailure:
            pass  # The fixture models unit-test bundles; only the pre-execution restart matters here.
        self.assertEqual([step for step in self.storekit_restarts() if step], ['discovery', 'test'])
        self.assertFalse((self.root / 'ui-native/storekitd-before-test.command.json').exists())
        self.calls.clear()
        self.runner.phase('ui-preparation', self.build)
        self.assertEqual([step for step in self.storekit_restarts() if step], ['restart', 'discovery', 'restart', 'test'])

    def test_shut_down_device_skips_the_storekitd_restart(self):
        self.device_state = 'Shutdown'
        self.runner.phase('native-preparation', self.build)
        self.assertNotIn('restart', self.storekit_restarts())

    def test_ordinary_builds_never_restart_storekitd(self):
        ordinary = self.root / 'build-ios.json'
        EVIDENCE.write(ordinary, dict(EVIDENCE.read(self.build), scheme='CodexBarIOS', native=False,
                                      derivedData=str(self.root / 'DerivedData-ios')))
        with patch.object(self.runner, 'arguments', return_value=['xcodebuild']), \
                patch.object(RUNNER, 'discovery_tests', return_value=[]), patch.object(RUNNER, 'validate_results'), \
                patch.object(RUNNER, 'validate_receipt'):
            try:
                self.runner.phase('ui-supplemental', ordinary)
            except (ValueError, RUNNER.PhaseFailure):
                pass
        self.assertNotIn('restart', self.storekit_restarts())

    def process(self, argv, **kwargs):
        self.calls.append(argv)
        stream = kwargs['stdout']
        if '-enumerate-tests' in argv:
            tests = sorted(item.removeprefix('-only-testing:') for item in argv if item.startswith('-only-testing:'))
            EVIDENCE.write(argv[argv.index('-test-enumeration-output-path')+1], discovery_fixture(tests))
            stream.write('enumerated\n')
        elif '-resultBundlePath' in argv:
            path = Path(argv[argv.index('-resultBundlePath')+1])
            path.mkdir()
            (path / 'Info.plist').write_text(path.parent.name)
            stream.write('retained xcode execution log\n')
            return SimpleNamespace(returncode=self.exit_codes.get(path.parent.name, 0))
        elif 'test-results' in argv:
            if self.extraction_error:
                raise OSError('diagnostic extraction unavailable')
            phase = Path(argv[-1]).parent.name
            if self.lazy_result_database:
                (Path(argv[-1]) / 'database.sqlite3').write_text('lazy xcresult index')
            tests = self.manifest['phases'][phase]['tests']
            summary, tree, _ = result_fixture(tests)
            summary.update(startTime=time.time() - .1, finishTime=time.time())
            stream.write(json.dumps(summary if 'summary' in argv else tree))
        else:
            stream.write('diagnostic attachment export\n')
        return SimpleNamespace(returncode=0)

    def test_receipt_hash_includes_database_created_by_result_inspection(self):
        self.lazy_result_database = True
        receipt = self.runner.phase('native-preparation', self.build)
        self.assertEqual(receipt['result_sha256'], EVIDENCE.digest(receipt['result']))

    def test_primary_65_survives_phase_receipt_write_failure(self):
        self.exit_codes['native-preparation'] = 65
        original_write = RUNNER.write
        def write(path, value):
            if path.name == 'receipt.json':
                raise OSError('receipt volume full')
            original_write(path, value)
        with patch.object(RUNNER, 'write', side_effect=write), self.assertRaises(RUNNER.PhaseFailure) as caught:
            self.runner.phase('native-preparation', self.build)
        self.assertEqual(caught.exception.code, 65)
        self.assertIn('retained xcode execution log', (self.root / 'native-preparation/xcodebuild.log').read_text())
        self.assertEqual(sum('-resultBundlePath' in call for call in self.calls), 1)

    def test_primary_65_survives_command_receipt_and_extraction_failure(self):
        self.exit_codes['native-preparation'] = 65
        self.extraction_error = True
        original_write = RUNNER.write
        def write(path, value):
            if path.name == 'xcodebuild.command.json':
                raise OSError('command receipt volume full')
            original_write(path, value)
        with patch.object(RUNNER, 'write', side_effect=write), self.assertRaises(RUNNER.PhaseFailure) as caught:
            self.runner.phase('native-preparation', self.build)
        self.assertEqual(caught.exception.code, 65)
        receipt = EVIDENCE.read(self.root / 'native-preparation/receipt.json')
        self.assertEqual(receipt['exit'], 65)
        self.assertIn('diagnostic extraction unavailable', receipt['validationError'])
        self.assertEqual(sum('-resultBundlePath' in call for call in self.calls), 1)

    def test_successful_xcode_with_required_receipt_failure_fails_gate(self):
        original_write = RUNNER.write
        def write(path, value):
            if path.name == 'receipt.json':
                raise OSError('receipt volume full')
            original_write(path, value)
        with patch.object(RUNNER, 'write', side_effect=write), self.assertRaises(RUNNER.PhaseFailure) as caught:
            self.runner.phase('native-preparation', self.build)
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(EVIDENCE.read(self.root / 'native-preparation/xcodebuild.command.json')['exit'], 0)

    def test_failed_preparation_never_replays_or_executes_consumer_and_reset_is_separate(self):
        self.exit_codes.update({'native-preparation': 65, 'ui-reset': 66})
        outcome = RUNNER.sequence(['native-preparation', 'native-commerce'],
                                  lambda name: self.runner.phase(name, self.build),
                                  lambda: self.runner.phase('ui-reset', self.build))
        self.assertEqual(outcome['exit'], 65)
        self.assertIn('(65)', outcome['primaryFailure'])
        self.assertIn('(66)', outcome['cleanupFailure'])
        tests = [call for call in self.calls if '-resultBundlePath' in call]
        self.assertEqual(len(tests), 2)
        self.assertEqual([Path(call[call.index('-resultBundlePath')+1]).parent.name for call in tests],
                         ['native-preparation', 'ui-reset'])
        for call in tests:
            self.assertEqual(sum(item.startswith('-only-testing:') for item in call), 1)
        self.assertTrue((self.root / 'native-preparation/result.xcresult').exists())
        self.assertTrue((self.root / 'ui-reset/result.xcresult').exists())

    def test_successful_work_with_failed_reset_fails_gate(self):
        self.exit_codes['ui-reset'] = 67
        outcome = RUNNER.sequence(['native-preparation'], lambda name: self.runner.phase(name, self.build),
                                  lambda: self.runner.phase('ui-reset', self.build))
        self.assertEqual(outcome['exit'], 67)
        self.assertIsNone(outcome['primaryFailure'])
        self.assertIn('(67)', outcome['cleanupFailure'])

    def test_discovery_failure_never_executes_storekit_tests(self):
        def fail_discovery(argv, **kwargs):
            self.calls.append(argv)
            kwargs['stdout'].write('discovery failed\n' if '-enumerate-tests' in argv else 'storekitd stopped\n')
            return SimpleNamespace(returncode=70 if '-enumerate-tests' in argv else 0)
        with patch.object(RUNNER.subprocess, 'run', side_effect=fail_discovery), self.assertRaises(RUNNER.PhaseFailure) as caught:
            self.runner.phase('native-preparation', self.build)
        self.assertEqual(caught.exception.code, 70)
        self.assertFalse(any('-resultBundlePath' in call for call in self.calls))
        self.assertEqual(EVIDENCE.read(self.root / 'native-preparation/discovery.command.json')['exit'], 70)

    def test_unfiltered_native_command_is_refused_before_process(self):
        with self.assertRaisesRegex(ValueError, 'unfiltered'):
            self.runner.arguments('CodexBarProNativeCommerce', self.root)
        self.assertEqual(self.calls, [])

    def test_replaced_build_is_refused_before_discovery(self):
        build = EVIDENCE.read(self.build)
        build['source'] = {'revision': 'stale'}
        EVIDENCE.write(self.build, build)
        with self.assertRaisesRegex(ValueError, 'source/toolchain/result'):
            self.runner.phase('native-preparation', self.build)
        self.assertEqual(self.calls, [])

    def test_native_use_marker_blocks_cross_directory_reuse_even_without_outcome(self):
        ownership = self.root / 'ownership.json'
        EVIDENCE.write(ownership, {})
        execution = self.root / 'separate-execution'
        RUNNER.claim_native_device(ownership, execution, self.device)
        with self.assertRaisesRegex(ValueError, 'already used'):
            RUNNER.owned_device(ownership, {})
        with self.assertRaises(FileExistsError):
            RUNNER.claim_native_device(ownership, execution, self.device)


class BuiltProductsTests(unittest.TestCase):
    def test_separate_test_bundle_and_xctestrun_are_hashed(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            products = derived / 'Build/Products'
            app = products / 'Debug-iphonesimulator/App.app'
            tests = products / 'Debug-iphonesimulator/AppTests.xctest'
            for bundle in (app, tests):
                bundle.mkdir(parents=True)
                (bundle / 'binary').write_bytes(b'compiled')
            configuration = products / 'App_iphonesimulator.xctestrun'
            configuration.write_bytes(b'configuration')
            signature = SimpleNamespace(returncode=0, stderr='Signature=adhoc')
            with patch.object(RUNNER.subprocess, 'run', return_value=signature):
                inventory = RUNNER.binaries(derived, True)
            self.assertEqual({item['path'] for item in inventory}, {str(app), str(tests), str(configuration)})
            for path in (tests / 'binary', configuration):
                original = path.read_bytes()
                path.write_bytes(b'changed')
                self.assertTrue(any(EVIDENCE.digest(item['path']) != item['sha256'] for item in inventory))
                path.write_bytes(original)


class RuntimeIdentityTests(unittest.TestCase):
    def setUp(self):
        self.identifier = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        self.device_id = '66F5FBE8-C47A-4841-9B2F-6ECF8FF8FBBB'
        self.inventory = dict(
            runtimes=[dict(identifier=self.identifier, version='27.0', buildversion=build,
                           bundlePath='/installed/' + build + '.simruntime', isAvailable=True)
                      for build in ('24A5390f', '24A434')],
            devices={self.identifier: [dict(udid=self.device_id, name='CodexBar 470 iphone fixture',
                       deviceTypeIdentifier='iPhone-Type', isAvailable=True, state='Shutdown')]},
            devicetypes=[dict(identifier='iPhone-Type', name='iPhone 17')])
        self.tools = dict(architecture='arm64', sdk='27.1')

    def test_duplicate_runtime_version_never_silently_selects_first_build(self):
        with patch.object(RUNNER, 'capture', return_value=json.dumps(self.inventory)):
            with self.assertRaisesRegex(ValueError, 'ambiguous'):
                RUNNER.device_record(self.device_id, 'iphone', self.tools)
            actual = RUNNER.device_record(self.device_id, 'iphone', self.tools, '/installed/24A434.simruntime')
        self.assertEqual(actual['osBuildNumber'], '24A434')

    def test_ambiguous_provision_fails_before_creating_any_device(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'capture', return_value=json.dumps(self.inventory)), patch.object(RUNNER, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'Ambiguous runtime builds'):
                RUNNER.provision(Path(folder), 'iphone', self.tools, supplementary=True)
            command.assert_not_called()

    def test_explicit_observed_build_creates_with_exact_bundle_path(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            def create(_, name, argv):
                (output / 'create-device.log').write_text(self.device_id)
                return dict(command=argv, exit=0)
            with patch.object(RUNNER, 'capture', return_value=json.dumps(self.inventory)), patch.object(RUNNER, 'command', side_effect=create):
                actual = RUNNER.provision(output, 'iphone', self.tools, supplementary=True, runtime_build='24A434')
            receipt = EVIDENCE.read(output / 'ownership.json')
            self.assertEqual(receipt['created']['command'][-1], '/installed/24A434.simruntime')
            self.assertEqual(actual['osBuildNumber'], '24A434')


class QualifiedRuntimeTests(unittest.TestCase):
    """Release phases use the 26.2 runtime; 26.5 breaks SKTestSession (FB22237318)."""
    def test_qualification_selects_only_the_unaffected_ios_runtime(self):
        identifier = lambda version: 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-')
        inventory = dict(runtimes=[dict(identifier=identifier(version), version=version, buildversion=build,
                                        bundlePath='/installed/' + build + '.simruntime', isAvailable=True)
                                   for version, build in (('26.2', '23C54'), ('26.4.1', '23E254a'), ('26.5', '23F77'))],
                         devices={identifier(version): [dict(udid=version, name='Default', deviceTypeIdentifier='iPhone-Type',
                                                            isAvailable=True, state='Shutdown')]
                                  for version in ('26.2', '26.4.1', '26.5')},
                         devicetypes=[dict(identifier='iPhone-Type', name='iPhone 17')])
        tools = dict(xcode=EVIDENCE.read(EVIDENCE.ROOT / 'scripts/function-risk/policy.json')['tools']['xcode'],
                     swift='swift', developer_dir='/dev', sdk='26.5', sdk_build='23F81a', architecture='arm64', image='image')
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'capture', return_value=json.dumps(inventory)), \
                patch.object(RUNNER, 'command', side_effect=AssertionError('stop after selection')) as command:
            with self.assertRaisesRegex(AssertionError, 'stop after selection'):
                RUNNER.provision(Path(folder), 'iphone', tools)
            self.assertEqual(command.call_args.args[2][-1], '/installed/23C54.simruntime')
        device = dict(osVersion='26.2', osBuildNumber='23C54')
        EVIDENCE.require_pinned(tools, device)
        with self.assertRaisesRegex(ValueError, '26.2 / 23C54'):
            EVIDENCE.require_pinned(tools, dict(osVersion='26.5', osBuildNumber='23F77'))


class OriginalUIRunnerTests(unittest.TestCase):
    """Run the real Bash entrypoint with fake xcrun/Python, never a simulator."""
    def run_entrypoint(self, family='iphone', identifier='owned-device', ownership=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        inventory = dict(runtimes=[dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                                        version='27.0', isAvailable=True)],
                         devices={'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [dict(
                             udid='owned-device', name='CodexBar 470 iphone fixture',
                             deviceTypeIdentifier='phone-model', isAvailable=True)]},
                         devicetypes=[dict(identifier='phone-model', name='iPhone 17')])
        (root / 'inventory.json').write_text(json.dumps(inventory))
        (root / 'xcrun').write_text('#!/bin/sh\ncase "$*" in\n  "--sdk iphonesimulator --show-sdk-version") echo 27.0;;\n  *) cat "$MOCK_INVENTORY";;\nesac\n')
        (root / 'python3').write_text('''#!/bin/sh
printf '%s\\n' "$@" > "$MOCK_ARGUMENTS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then
    shift
    printf '%s\\n' '{"result":"Passed","totalTestCount":29,"passedTests":29,"failedTests":0,"skippedTests":0,"expectedFailures":0}' > "$1/summary.json"
    exit 0
  fi
  shift
done
exit 1
''')
        for name in ('xcrun', 'python3'):
            (root / name).chmod(0o755)
        arguments = root / 'arguments.txt'
        environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                           UI_TEST_REQUIRE_DEVICE_ID='1', UI_TEST_DEVICE_ID=identifier, UI_TEST_DEVICE_NAME='',
                           UI_TEST_OWNERSHIP_RECEIPT=ownership or '', UI_TEST_RESULTS_DIR=str(root / 'results'),
                           MOCK_INVENTORY=str(root / 'inventory.json'), MOCK_ARGUMENTS=str(arguments))
        result = subprocess.run(['/bin/bash', str(SCRIPTS / 'run-ui-tests.sh'), family],
                                env=environment, capture_output=True, text=True)
        return result, arguments.read_text().splitlines() if arguments.exists() else []

    def test_owned_display_name_uses_model_and_empty_optional_array_works_on_bash_3(self):
        result, arguments = self.run_entrypoint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('owned-device', arguments)
        self.assertNotIn('--ownership', arguments)

    def test_owned_runtime_receipt_reaches_base_runner(self):
        result, arguments = self.run_entrypoint(ownership='/owned/receipt.json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments[-2:], ['--ownership', '/owned/receipt.json'])

    def test_missing_owned_id_or_wrong_family_never_launches_base_runner(self):
        for options in (dict(identifier=''), dict(family='ipad')):
            result, arguments = self.run_entrypoint(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(arguments, [])


if __name__ == '__main__':
    unittest.main()
