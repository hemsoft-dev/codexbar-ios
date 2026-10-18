"""Manual-only release harness fixtures; no Xcode, simulator, or network work."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import release_evidence as EVIDENCE
import pro_release_runner as RUNNER


def result_fixture(identities):
    device = dict(deviceId='owned-device', modelName='iPhone 17', osVersion='26.5',
                  osBuildNumber='23F77', architecture='arm64', platform='iOS Simulator', family='iphone')
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
        self.assertEqual(EVIDENCE.discovery_tests({'values': self.expected}), self.expected)
        for value in ({'tests': []}, {'tests': self.expected * 2}, {'tests': ['ExampleTests']}):
            with self.assertRaises(ValueError):
                EVIDENCE.discovery_tests(value)


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
        self.patches = [patch.object(self.runner, 'unchanged'),
                        patch.object(RUNNER.subprocess, 'run', side_effect=self.process)]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def process(self, argv, **kwargs):
        self.calls.append(argv)
        stream = kwargs['stdout']
        if '-enumerate-tests' in argv:
            tests = sorted(item.removeprefix('-only-testing:') for item in argv if item.startswith('-only-testing:'))
            EVIDENCE.write(argv[argv.index('-test-enumeration-output-path')+1], {'values': tests})
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
            tests = self.manifest['phases'][phase]['tests']
            summary, tree, _ = result_fixture(tests)
            summary.update(startTime=time.time() - .1, finishTime=time.time())
            stream.write(json.dumps(summary if 'summary' in argv else tree))
        else:
            stream.write('diagnostic attachment export\n')
        return SimpleNamespace(returncode=0)

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
            kwargs['stdout'].write('discovery failed\n')
            return SimpleNamespace(returncode=70)
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


if __name__ == '__main__':
    unittest.main()
