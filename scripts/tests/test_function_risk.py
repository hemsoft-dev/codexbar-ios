"""Regression fixtures exercise coverage joining and the required gate without Xcode."""
import copy
from fractions import Fraction
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('function_risk', Path(__file__).parents[1] / 'function-risk/measure.py')
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)
import coverage_inputs as INPUTS
import release_evidence as EVIDENCE
from scripts.tests.test_pro_release_validation import discovery_fixture, result_fixture


class FunctionRiskTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.patcher = patch.object(METRICS, 'ROOT', self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        (self.root / 'Example.swift').write_text('func uncovered(_ value: Int) {\n' + '\n'.join(f'    if value == {i} {{ print(value) }}' for i in range(6)) + '\n}\n')
        self.declaration = dict(path='Example.swift', symbol='.func uncovered ( _ value : Int )', kind='function', line=1, bodyLine=1, endLine=8, lintLine=1, lintColumn=1)
        self.complexity = [dict(file=str(self.root / 'Example.swift'), line=1, character=1, rule_id='cyclomatic_complexity', reason='Function should have complexity -1 or less; currently complexity is 6')]
        self.function = dict(name='uncovered(_:)', lineNumber=1, coveredLines=0, executableLines=8)
        self.target = dict(name='Example.app', coveredLines=0, executableLines=8, files=[dict(path=str(self.root / 'Example.swift'), functions=[self.function])])
        self.policy = dict(platforms=dict(ios=dict(coverage_targets=['Example.app'])), excluded_files={}, excluded_symbols={})
        self.baseline = dict(platforms=dict(ios=dict(high_risk={}, unmatched={})))

    def measure(self, declarations=None, targets=None):
        return METRICS.measure('ios', declarations or [self.declaration], self.complexity, dict(targets=targets or [self.target]), {'Example.swift'}, self.policy)

    def test_uncovered_branch_fixture_fails_then_restored_coverage_passes(self):
        report = self.measure()
        self.assertEqual(report['functions'][0]['crap_exact'], '42/1')
        self.assertIn('New production risk above 30', METRICS.gate(report, self.baseline)[0])
        self.function['coveredLines'] = 8
        self.assertEqual(METRICS.gate(self.measure(), self.baseline), [])

    def test_worsened_baseline_fails_even_below_display_precision(self):
        report = self.measure()
        row = report['functions'][0]
        row.update(complexity=20, covered_lines=96, executable_lines=137)
        self.baseline['platforms']['ios']['high_risk'][row['id']] = copy.deepcopy(row)
        self.assertEqual(METRICS.gate(report, self.baseline), [])
        before = float(METRICS.risk(row))
        row.update(covered_lines=96 * 10 ** 10 - 1, executable_lines=137 * 10 ** 10)
        self.assertEqual(f'{before:.4f}', f'{float(METRICS.risk(row)):.4f}')
        self.assertIn('Baseline risk increased', METRICS.gate(report, self.baseline)[0])

    def test_missing_coverage_never_means_covered(self):
        self.target['files'][0]['functions'] = []
        report = self.measure()
        self.assertEqual(report['functions'][0]['status'], 'unmatched')
        self.assertNotIn('coverage', report['functions'][0])
        self.assertIn('Unmatched production', METRICS.gate(report, self.baseline)[0])

    def test_duplicate_declarations_fail_instead_of_choosing_one(self):
        self.target['files'][0]['functions'].append(copy.deepcopy(self.function))
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_missing_required_target_fails_with_evidence(self):
        self.target["name"] = "Other.app"
        report = self.measure()
        self.assertIn("Missing coverage target Example.app", report["errors"])
        self.assertTrue(METRICS.gate(report, self.baseline))

    def test_zero_executable_lines_fail(self):
        self.function['executableLines'] = 0
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_missing_complexity_fails_even_with_full_coverage(self):
        self.complexity = []
        self.function['coveredLines'] = 8
        self.assertEqual(self.measure()['functions'][0]['status'], 'unmatched')

    def test_other_platform_never_supplies_coverage(self):
        incidental = copy.deepcopy(self.target)
        incidental['name'] = 'Watch.app'
        incidental['files'][0]['functions'][0]['coveredLines'] = 8
        report = self.measure(targets=[self.target, incidental])
        self.assertEqual(report['functions'][0]['covered_lines'], 0)
        self.assertEqual(report['excluded_coverage'][0]['target'], 'Watch.app')

    def test_source_hash_exception_invalidates_after_change(self):
        self.target['files'][0]['functions'] = []
        report = self.measure()
        row = report['functions'][0]
        self.baseline['platforms']['ios']['unmatched'][row['id']] = dict(source_sha256=row['source_sha256'], complexity=6, reason='Fixture unavailable on this platform')
        self.assertEqual(METRICS.gate(report, self.baseline), [])
        (self.root / 'Example.swift').write_text('func uncovered(_ value: Int) { fatalError() }')
        self.assertEqual(METRICS.gate(self.measure(), self.baseline), [
            'Unmatched production declaration needs reviewed evidence: ' + row['id'],
        ])

    def test_removed_high_risk_symbol_requires_baseline_review(self):
        self.baseline['platforms']['ios']['high_risk']['deleted'] = dict(complexity=6, covered_lines=0, executable_lines=8)
        self.assertTrue(any('disappeared' in error for error in METRICS.gate(self.measure(), self.baseline)))

    def test_invalid_counts_are_rejected(self):
        for covered, executable in [(9, 8), (-1, 8), (0, 0), (True, 8)]:
            with self.assertRaises(ValueError):
                METRICS.score(6, covered, executable)
        self.assertEqual(METRICS.score(6, 4, 8), Fraction(21, 2))

    def test_line_shift_preserves_baseline_identity(self):
        before = self.measure()['functions'][0]['id']
        self.declaration.update(line=2, bodyLine=2, endLine=9, lintLine=2)
        self.complexity[0]['line'] = 2
        self.function['lineNumber'] = 2
        self.assertEqual(self.measure()['functions'][0]['id'], before)

    def test_accessors_and_closures_stay_visible_without_fake_complexity(self):
        self.target['files'][0]['functions'].append(dict(self.function, name='closure #1 in uncovered(_:)'))
        self.target['files'][0]['functions'].append(dict(self.function, name='Example.body.getter'))
        report = self.measure()
        self.assertEqual(len(report['excluded_coverage']), 2)
        self.assertEqual(report['functions'][0]['complexity'], 6)
        self.assertIsNone(METRICS.unmeasured_kind('Example.readSecret(account:)'))


class ProjectSourcesTests(unittest.TestCase):
    def project(self, source_tree='<group>', path='Example.swift'):
        return {'rootObject': 'project', 'objects': {
            'project': {'mainGroup': 'root'},
            'root': {'isa': 'PBXGroup', 'children': ['group', 'product']},
            'group': {'isa': 'PBXGroup', 'path': 'Sources', 'children': ['source']},
            'source': {'isa': 'PBXFileReference', 'path': path, 'sourceTree': source_tree},
            'product': {'isa': 'PBXFileReference', 'path': 'App.app', 'sourceTree': 'BUILT_PRODUCTS_DIR'},
            'build': {'fileRef': 'source'},
            'phase': {'isa': 'PBXSourcesBuildPhase', 'files': ['build']},
            'target': {'isa': 'PBXNativeTarget', 'name': 'App', 'buildPhases': ['phase']},
        }}

    def test_source_root_ignores_containing_group(self):
        project = self.project('SOURCE_ROOT', 'Sources/Example.swift')
        self.assertEqual(METRICS.project_sources(project, ['App']), {'Sources/Example.swift'})

    def test_group_relative_control_and_unused_product_root(self):
        self.assertEqual(METRICS.project_sources(self.project(), ['App']), {'Sources/Example.swift'})

    def test_nested_source_root_group_resets_parent(self):
        project = self.project()
        project['objects']['root']['path'] = 'Parent'
        project['objects']['group']['sourceTree'] = 'SOURCE_ROOT'
        self.assertEqual(METRICS.project_sources(project, ['App']), {'Sources/Example.swift'})

    def test_unsupported_source_root_and_escape_fail(self):
        for tree, path in [('SDKROOT', 'Example.swift'), ('<absolute>', '/tmp/Example.swift'),
                           ('SOURCE_ROOT', '../Example.swift'), ('<group>', '$(SRCROOT)/Example.swift')]:
            with self.subTest(tree=tree, path=path), self.assertRaises(ValueError):
                METRICS.project_sources(self.project(tree, path), ['App'])

    def test_ambiguous_group_membership_fails(self):
        project = self.project()
        project['objects']['root']['children'].append('other')
        project['objects']['other'] = {'isa': 'PBXGroup', 'path': 'Other', 'children': ['source']}
        with self.assertRaises(ValueError):
            METRICS.project_sources(project, ['App'])


class CoverageInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.function = dict(name='branch(_:)', lineNumber=1, coveredLines=2, executableLines=4)
        self.file = dict(path=str(self.root / 'Source.swift'), coveredLines=2, executableLines=4,
                         functions=[self.function])
        self.target = dict(name='App.app', coveredLines=2, executableLines=4, files=[self.file])
        self.report = dict(targets=[self.target])

    def index(self, report=None):
        return INPUTS.coverage_index(report or self.report, self.root, {'Source.swift'})

    def test_duplicate_targets_cannot_disappear_in_name_dictionary(self):
        self.report['targets'].append(copy.deepcopy(self.target))
        with self.assertRaisesRegex(ValueError, 'Duplicate coverage identity'):
            self.index()

    def test_duplicate_files_and_functions_fail(self):
        for level in ('files', 'functions'):
            with self.subTest(level=level):
                report = copy.deepcopy(self.report)
                parent = report['targets'][0] if level == 'files' else report['targets'][0]['files'][0]
                parent[level].append(copy.deepcopy(parent[level][0]))
                with self.assertRaisesRegex(ValueError, 'Duplicate coverage identity'):
                    self.index(report)

    def test_invalid_counts_and_empty_targets_fail(self):
        for covered, executable in [(5, 4), (-1, 4), (True, 4), (0, -1)]:
            with self.subTest(covered=covered, executable=executable):
                self.function.update(coveredLines=covered, executableLines=executable)
                with self.assertRaisesRegex(ValueError, 'Invalid coverage counters'):
                    self.index()
        with self.assertRaisesRegex(ValueError, 'empty coverage target'):
            INPUTS.require_counters({}, ['App.app'])
        with self.assertRaisesRegex(ValueError, 'empty coverage target'):
            INPUTS.require_counters({('target', 'App.app'): (0, 4)}, ['App.app'], covered=True)

    def test_stale_source_path_fails_but_external_generated_source_is_visible(self):
        self.file['path'] = '/previous-checkout/Source.swift'
        with self.assertRaisesRegex(ValueError, 'Stale production source path'):
            self.index()
        self.file['path'] = '/DerivedData/Generated.swift'
        self.assertEqual(len(self.index()), 3)

    def test_every_matching_denominator_must_agree_before_merge(self):
        original = self.index()
        for key in original:
            with self.subTest(key=key):
                altered = dict(original)
                altered[key] = (2, 5)
                with self.assertRaisesRegex(ValueError, 'denominators'):
                    INPUTS.validate_union([original, altered], None)

    def test_ordinary_and_native_counters_both_survive_without_computing_union(self):
        ordinary = {('function', 'App.app', 'source', 1, 'ordinary'): (3, 4),
                    ('function', 'App.app', 'source', 6, 'native'): (0, 4)}
        native = {('function', 'App.app', 'source', 1, 'ordinary'): (0, 4),
                  ('function', 'App.app', 'source', 6, 'native'): (3, 4)}
        merged = {key: (3, 4) for key in ordinary}
        INPUTS.validate_union([ordinary, native], merged)
        with self.assertRaisesRegex(ValueError, 'lost covered lines'):
            INPUTS.validate_union([ordinary, native], ordinary)
        with self.assertRaisesRegex(ValueError, 'lost identity'):
            INPUTS.validate_union([ordinary, native], {})
        with self.assertRaisesRegex(ValueError, 'unexpected identities'):
            INPUTS.validate_union([ordinary, native], dict(merged, unexpected=(0, 1)))

    def test_export_requires_one_matching_raw_pair_and_a_fresh_directory(self):
        def export(command):
            folder = Path(command[-1])
            (folder / 'action.xccovreport').write_bytes(b'report')
            (folder / 'action.xccovarchive').mkdir()
            return ''
        output = self.root / 'raw'
        report, archive = INPUTS.export_pair(self.root / 'input.xcresult', output, export)
        self.assertEqual(report.stem, archive.stem)
        with self.assertRaises(FileExistsError):
            INPUTS.export_pair(self.root / 'input.xcresult', output, export)
        with self.assertRaisesRegex(ValueError, 'unambiguous'):
            INPUTS.export_pair(self.root / 'input.xcresult', self.root / 'empty', lambda _: '')

    def test_export_preserves_actual_extensionless_names_and_normalizes_for_xccov(self):
        def export(argv):
            folder = Path(argv[-1])
            (folder / '0_Test_My Mac_CoverageReport').write_bytes(b'raw report')
            (folder / '0_Test_My Mac_CoverageArchive').mkdir()
            (folder / '0_Test_My Mac_CoverageArchive/Index').write_bytes(b'raw index')
        output = self.root / 'actual-layout'
        report, archive = INPUTS.export_pair(self.root / 'input.xcresult', output, export)
        self.assertEqual(report.read_bytes(), b'raw report')
        self.assertEqual((archive / 'Index').read_bytes(), b'raw index')
        mapping = EVIDENCE.read(output / 'export-paths.json')
        self.assertEqual(EVIDENCE.digest(mapping['report']), EVIDENCE.digest(report))
        self.assertEqual(EVIDENCE.digest(mapping['archive']), EVIDENCE.digest(archive))


class CoverageCollectionTests(unittest.TestCase):
    """End-to-end collection contract with fake native tools, real files/hashes."""
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.output = self.root / 'output'
        self.output.mkdir()
        self.phases = EVIDENCE.load_manifest()
        self.source = dict(revision='a' * 40, root=str(self.root), status='', files={'Source.swift': 'b' * 64})
        self.tools = dict(xcode='Xcode 26.6\nBuild version 17F113', sdk='26.5', sdk_build='recorded-build',
                          swift='recorded-swift', developer_dir='/Applications/Xcode_26.6.app/Contents/Developer',
                          architecture='arm64', image='fixture')
        _, _, self.device = result_fixture(['CodexBarIOSTests/ExampleTests/testFirst'])
        self.policy = dict(platforms=dict(ios=dict(coverage_targets=['App.app', 'Widget.appex']),
                                         watch=dict(coverage_targets=['App.app', 'Widget.appex'])))
        self.coverage = dict(targets=[dict(name=name, coveredLines=2, executableLines=4,
                             files=[dict(path=str(self.root / 'Source.swift'), coveredLines=2, executableLines=4,
                                         functions=[dict(name='branch(_:)', lineNumber=1, coveredLines=2, executableLines=4)])])
                            for name in ['App.app', 'Widget.appex']])
        self.receipts, self.entries, self.summaries, self.trees, self.commands = {}, [], {}, {}, []
        self.mutate_result_reads = False
        self.native_build = self.make_build('native', True)
        ordinary_build = self.make_build('ordinary', False)
        for index, phase in enumerate(self.phases['coverage_phases']):
            folder = self.root / phase
            folder.mkdir()
            result = folder / 'result.xcresult'
            result.mkdir()
            (result / 'Info.plist').write_text(phase)
            expected = self.phases['shared_pro_tests'] if phase == 'ios' else self.phases['phases'][phase]['tests']
            summary, tree, _ = result_fixture(expected)
            summary.update(startTime=100 + index * 10, finishTime=101 + index * 10)
            self.summaries[str(result)] = summary
            self.trees[str(result)] = tree
            discovery = folder / 'discovery.json'
            EVIDENCE.write(discovery, discovery_fixture(expected))
            build_path = ordinary_build if phase == 'ios' else self.native_build
            build = EVIDENCE.read(build_path)
            argv = build['command'][:-1] + ([] if phase == 'ios' else ['-only-testing:' + test for test in expected])
            discovery_argv = argv + ['test-without-building', '-enumerate-tests', '-test-enumeration-output-path', str(discovery)]
            argv += ['-resultBundlePath', str(result), 'test-without-building']
            receipt = dict(schema=1, phase=phase, exit=0, source=self.source, tools=self.tools, platform='ios',
                           configuration='Debug', expectedTests=sorted(expected), executedTests=sorted(expected),
                           result=str(result), result_sha256=EVIDENCE.digest(result), device=copy.deepcopy(self.device),
                           command=argv, buildReceipt=str(build_path), build_sha256=EVIDENCE.digest(build_path),
                           discovery=str(discovery), discovery_sha256=EVIDENCE.digest(discovery), discoveryCommand=discovery_argv,
                           started=f'1970-01-01T00:0{(100+index*10)//60}:{(100+index*10)%60:02}+00:00',
                           ended=f'1970-01-01T00:0{(101+index*10)//60}:{(101+index*10)%60:02}+00:00')
            path = folder / 'receipt.json'
            EVIDENCE.write(path, receipt)
            self.receipts[phase] = receipt
            self.entries.append(dict(phase=phase, result=str(result), receipt=str(path)))
        self.manifest = dict(schema=1, complete=True, platform='ios', source=self.source,
                             tools=self.tools, inputs=self.entries)
        self.path = self.root / 'inputs.json'
        self.patcher = patch.object(INPUTS, 'source_snapshot', return_value=self.source)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def make_build(self, label, native):
        scheme = 'CodexBarProNativeCommerce' if native else 'CodexBarIOS'
        derived = str(self.root / ('DerivedData-' + label))
        argv = ['xcodebuild', '-scheme', scheme, '-configuration', 'Debug', '-enableCodeCoverage', 'YES',
                '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
                '-derivedDataPath', derived, '-destination', 'platform=iOS Simulator,id=owned-device',
                'CODE_SIGNING_ALLOWED=' + ('YES' if native else 'NO')]
        if native:
            argv.append('CODE_SIGN_IDENTITY=-')
        path = self.root / (label + '-build.json')
        EVIDENCE.write(path, dict(source=self.source, tools=self.tools, exit=0, binaries=[dict(path='fixture', sha256='fixture')],
                                  configuration='Debug', coverage=True, native=native, adhocSigned=native,
                                  scheme=scheme, device=copy.deepcopy(self.device), derivedData=derived,
                                  command=argv + ['build-for-testing'], ended='1970-01-01T00:01:00+00:00'))
        return path

    def native_tool(self, command):
        self.commands.append(command)
        if self.mutate_result_reads and '--path' in command:
            result = Path(command[command.index('--path') + 1])
            (result / 'database.sqlite3').write_text('lazy index: ' + ' '.join(command))
        if command == ['xcodebuild', '-version']:
            return self.tools['xcode']
        if 'test-results' in command:
            phase = (Path(command[-1]) / 'Info.plist').read_text()
            original = str(self.root / phase / 'result.xcresult')
            return json.dumps((self.summaries if 'summary' in command else self.trees)[original])
        if 'export' in command:
            folder = Path(command[-1])
            (folder / 'action.xccovreport').write_text(str(folder))
            (folder / 'action.xccovarchive').mkdir()
            (folder / 'action.xccovarchive/Index').write_text(str(folder) + ':raw')
            return ''
        if 'merge' in command:
            Path(command[command.index('--outReport') + 1]).write_text('merged-report')
            Path(command[command.index('--outArchive') + 1]).write_text('merged-archive')
            return ''
        if 'view' in command:
            return json.dumps(self.coverage)
        raise AssertionError(command)

    def collect(self, single=False, platform='ios'):
        EVIDENCE.write(self.path, self.manifest)
        for entry in self.entries:
            EVIDENCE.write(entry['receipt'], self.receipts[entry['phase']])
        args = SimpleNamespace(inputs=None if single else self.path,
                               result=Path(self.entries[0]['result']) if single else None, platform=platform)
        return INPUTS.collect_coverage(args, self.output, self.policy, {'Source.swift'}, self.root, self.native_tool)

    def test_all_five_inputs_are_exported_merged_and_retained(self):
        _, evidence = self.collect()
        merge = next(command for command in self.commands if 'merge' in command)
        self.assertEqual(len(merge[7:]), 10)
        self.assertEqual([item['phase'] for item in evidence], self.phases['coverage_phases'])
        self.assertTrue(all(item['producer_attested'] for item in evidence))
        self.assertEqual(len(list((self.output / 'inputs').glob('*/test-summary.json'))), 5)

    def test_lazy_tool_indexes_never_mutate_attested_input_bundles(self):
        self.mutate_result_reads = True
        original_hashes = {entry['result']: EVIDENCE.digest(entry['result']) for entry in self.entries}
        _, evidence = self.collect()
        self.assertEqual({path: EVIDENCE.digest(path) for path in original_hashes}, original_hashes)
        self.assertEqual({item['result']: item['result_sha256'] for item in evidence}, original_hashes)
        for command in self.commands:
            if '--path' in command:
                self.assertNotIn(command[command.index('--path') + 1], original_hashes)

    def test_single_result_watch_interface_still_collects_without_merging(self):
        result = self.entries[0]['result']
        summary, tree, device = result_fixture(['CodexBarWatchTests/WatchTests/testFirst'])
        device.update(platform='watchOS Simulator', modelName='Apple Watch', family='watch')
        tree['testNodes'][0]['name'] = 'CodexBarWatchTests'
        self.summaries[result], self.trees[result] = summary, tree
        _, evidence = self.collect(single=True, platform='watch')
        self.assertFalse(any('merge' in command for command in self.commands))
        self.assertTrue((self.output / 'test-summary.json').exists())
        self.assertFalse(evidence[0]['producer_attested'])

    def test_single_watch_rejects_ios_execution_even_with_watch_counters(self):
        with self.assertRaisesRegex(ValueError, 'platform/bundle'):
            self.collect(single=True, platform='watch')

    def test_ordinary_filtered_execution_or_discovery_is_rejected(self):
        for key in ('command', 'discoveryCommand'):
            with self.subTest(key=key):
                receipt = copy.deepcopy(self.receipts['ios'])
                receipt[key].insert(1, '-only-testing:CodexBarIOSTests/SomeTests')
                with self.assertRaisesRegex(ValueError, 'must be unfiltered'):
                    EVIDENCE.validate_receipt(receipt, self.source, self.tools, receipt['expectedTests'],
                                              'ios', Path(receipt['result']))

    def test_missing_phase_is_rejected_before_export(self):
        self.manifest['inputs'] = self.entries[:-1]
        with self.assertRaisesRegex(ValueError, 'coverage phases'):
            self.collect()
        self.assertFalse(any('export' in command for command in self.commands))

    def test_duplicate_result_path_is_rejected(self):
        self.entries[1]['result'] = self.entries[0]['result']
        with self.assertRaisesRegex(ValueError, 'Duplicate coverage input'):
            self.collect()

    def test_stale_source_and_failed_setup_never_reach_merge(self):
        self.receipts['native-preparation']['source'] = dict(self.source, revision='c' * 40)
        with self.assertRaisesRegex(ValueError, 'Stale, dirty or different source'):
            self.collect()
        self.assertFalse(any('merge' in command for command in self.commands))

    def test_failed_or_skipped_native_results_never_reach_merge(self):
        self.summaries[self.entries[1]['result']]['skippedTests'] = 1
        with self.assertRaisesRegex(ValueError, 'skippedTests'):
            self.collect()
        self.assertFalse(any('merge' in command for command in self.commands))

    def test_native_cannot_relabel_an_ordinary_build(self):
        path = self.root / 'ordinary-build.json'
        self.receipts['native-preparation'].update(buildReceipt=str(path), build_sha256=EVIDENCE.digest(path))
        with self.assertRaisesRegex(ValueError, 'Wrong scheme/native build'):
            self.collect()

    def test_preparation_and_consumer_must_share_native_build(self):
        other = self.make_build('other-native', True)
        self.receipts['native-commerce'].update(buildReceipt=str(other), build_sha256=EVIDENCE.digest(other))
        for key in ('command', 'discoveryCommand'):
            command = self.receipts['native-commerce'][key]
            command[command.index('-derivedDataPath')+1] = EVIDENCE.read(other)['derivedData']
        with self.assertRaisesRegex(ValueError, 'one device and build'):
            self.collect()

    def test_preparation_must_finish_before_consumer_starts(self):
        self.receipts['native-commerce']['started'] = '1970-01-01T00:01:49+00:00'
        with self.assertRaisesRegex(ValueError, 'preparation/consumption order'):
            self.collect()

    def test_empty_app_counters_fail_before_merge(self):
        self.coverage['targets'][0].update(coveredLines=0, executableLines=0)
        with self.assertRaisesRegex(ValueError, 'empty coverage target'):
            self.collect()
        self.assertFalse(any('merge' in command for command in self.commands))


class MeasurementSourceIdentityTests(unittest.TestCase):
    """Reject a report whose inputs were collected across a source change."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.policy = METRICS.read(METRICS.POLICY)
        self.baseline = self.root / 'baseline.json'
        METRICS.write(self.baseline, dict(platforms={}))
        self.snapshot = dict(revision='a' * 40, root=str(self.root), status='', files={'Source.swift': '1' * 64})
        for target, value in (('ROOT', self.root), ('collect_coverage', lambda *_: ({}, [])),
                              ('project_sources', lambda *_: set()), ('gate', lambda *_: []),
                              ('measure', lambda *_: dict(platform='ios', functions=[])),
                              ('markdown', lambda _: ''), ('run', self.tool)):
            patcher = patch.object(METRICS, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def tool(self, command, **_):
        if command == ['xcodebuild', '-version']:
            return self.policy['tools']['xcode']
        if command[-1] == 'version':
            return self.policy['tools']['swiftlint']
        if command == ['xcrun', '--find', 'swiftc']:
            return str(self.root / 'usr/bin/swiftc')
        if command[:2] == ['xcrun', 'swiftc']:
            Path(command[-1]).write_text('')
            return ''
        if command[0].endswith('declarations-tool') or command[1:2] == ['lint']:
            return '[]'
        return '{}'

    def collect(self, final):
        output = self.root / 'risk'
        args = SimpleNamespace(platform='ios', inputs=self.root / 'inputs.json', result=None,
                               output=output, baseline=self.baseline)
        with patch.object(METRICS, 'source_snapshot', side_effect=[self.snapshot, final]) as snapshot:
            try:
                return METRICS.collect(args), output
            finally:
                self.assertEqual([call.kwargs for call in snapshot.call_args_list], [dict(require_clean=True)] * 2)

    def test_unchanged_source_reports_the_verified_revision(self):
        failed, output = self.collect(copy.deepcopy(self.snapshot))
        self.assertFalse(failed)
        self.assertEqual(METRICS.read(output / 'report.json')['tools']['revision'], self.snapshot['revision'])

    def test_source_change_during_collection_fails_without_a_report(self):
        changed_file = dict(copy.deepcopy(self.snapshot), files={'Source.swift': '2' * 64})
        new_commit = dict(copy.deepcopy(self.snapshot), revision='b' * 40)
        for final in (changed_file, new_commit):
            with self.subTest(final=final), self.assertRaisesRegex(ValueError, 'Source changed during'):
                self.collect(final)
            self.assertFalse((self.root / 'risk/report.json').exists())
            shutil.rmtree(self.root / 'risk')


if __name__ == '__main__':
    unittest.main()
