"""Manual-only shard completeness, provenance and cleanup failure controls."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import ui_release_shards as SHARDS
from release_evidence import load_manifest, read
from pro_release_runner import PhaseFailure


class UIShardTests(unittest.TestCase):
    def setUp(self):
        self.source = dict(revision='candidate', status='', files={'a.swift': 'hash'})
        self.plan = SHARDS.load_plan()
        self.tools = dict(xcode=read(SCRIPTS / 'function-risk/policy.json')['tools']['xcode'],
                          swift='qualified', developer_dir='/Applications/Xcode_26.6.app/Contents/Developer',
                          sdk='26.5', sdk_build='qualified', architecture='arm64', image='fixture')

    def proof(self, family, name):
        return dict(schema=1, complete=True, shutdown=True, revision='candidate',
                    sourceFingerprint=SHARDS.fingerprint(self.source), tools=self.tools,
                    family=family, shard=name, started='2026-10-24T12:00:00+00:00', ended='2026-10-24T13:00:00+00:00',
                    device=dict(family=family, architecture='arm64', platform='iOS Simulator', osVersion='26.2',
                                osBuildNumber='23C54', deviceId=family+'-'+name),
                    phases=[dict(phase=phase, tests=tests, receiptSha256='a'*64,
                                 started='2026-10-24T12:01:00+00:00', ended='2026-10-24T12:01:00+00:00')
                            for phase, tests in self.plan[name]])

    def test_all_journeys_are_partitioned_once_and_keep_native_sequence(self):
        manifest = load_manifest()
        actual = [test for phases in self.plan.values() for phase, tests in phases
                  if manifest['phases'][phase]['kind'] == 'journey' for test in tests]
        expected = [test for phase in manifest['ui_journeys'] for test in manifest['phases'][phase]['tests']]
        self.assertEqual(sorted(actual), sorted(expected))
        self.assertEqual(len(actual), 53)
        self.assertEqual(len(set(actual)), 53)
        self.assertEqual([len(self.plan[name][0][1]) for name in SHARDS.SHARDS[:3]], [8, 8, 13])
        self.assertEqual([phase for phase, _ in self.plan['native']],
                         ['ui-preparation', 'ui-native', 'ui-error-preparation', 'ui-native-purchase-error', 'ui-reset'])

    def test_original_partition_omission_duplicate_and_substitution_fail(self):
        original = SHARDS.read(SHARDS.PLAN)
        for mutation in ('missing', 'duplicate', 'other'):
            altered = copy.deepcopy(original)
            tests = altered['shards']['original-1']['tests']
            if mutation == 'missing': tests.pop()
            elif mutation == 'duplicate': tests.append(tests[0])
            else: tests[0] = 'CodexBarIOSUITests/Other/testSubstituted'
            with self.subTest(mutation=mutation), patch.object(SHARDS, 'read', return_value=altered), self.assertRaises(ValueError):
                SHARDS.load_plan()

    def test_native_schedule_cannot_omit_cleanup_or_change_preparation_order(self):
        original = SHARDS.read(SHARDS.PLAN)
        for mutation in ('reset', 'order', 'matrix'):
            altered = copy.deepcopy(original)
            if mutation == 'reset': altered['shards']['native']['cleanup'] = None
            elif mutation == 'order': altered['shards']['native']['phases'].reverse()
            else: del altered['shards']['synthetic']
            with self.subTest(mutation=mutation), patch.object(SHARDS, 'read', return_value=altered), self.assertRaises(ValueError):
                SHARDS.load_plan()

    def test_native_failure_preserves_primary_and_always_attempts_reset(self):
        runner = Mock(manifest=load_manifest())
        def phase(name, build):
            if name == 'ui-native': raise PhaseFailure('purchase failed', 65)
            if name == 'ui-reset': raise PhaseFailure('reset failed', 66)
        runner.phase.side_effect = phase
        with self.assertRaises(PhaseFailure) as caught:
            SHARDS.execute(runner, 'native', self.plan['native'])
        self.assertEqual(caught.exception.code, 65)
        self.assertEqual([call.args[0] for call in runner.phase.call_args_list], ['ui-preparation', 'ui-native', 'ui-reset'])
        self.assertTrue(runner.build.call_args.kwargs['native'])

    def test_non_native_shard_selects_exact_tests_and_does_not_build_storekit(self):
        runner = Mock(manifest=load_manifest())
        SHARDS.execute(runner, 'original-1', self.plan['original-1'])
        self.assertFalse(runner.build.call_args.kwargs['native'])
        self.assertEqual(runner.build.call_args.args[2], self.plan['original-1'][0][1])
        self.assertEqual(runner.phase.call_count, 1)

    def test_failed_execution_shuts_down_without_a_passing_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'run'
            device = self.proof('iphone', 'native')['device']
            with patch.object(SHARDS, 'source_snapshot', return_value=self.source), \
                    patch.object(SHARDS, 'toolchain', return_value=self.tools), \
                    patch.object(SHARDS, 'provision', return_value=device), \
                    patch.object(SHARDS, 'claim_native_device'), patch.object(SHARDS, 'command'), \
                    patch.object(SHARDS, 'Runner'), \
                    patch.object(SHARDS, 'execute', side_effect=PhaseFailure('journey failed', 65)), \
                    patch.object(SHARDS, 'shutdown', side_effect=PhaseFailure('shutdown failed', 66)) as shutdown:
                self.assertEqual(SHARDS.run_shard(output, 'iphone', 'native'), 65)
            shutdown.assert_called_once()
            self.assertFalse((output / 'proof.json').exists())
            self.assertFalse(read(output / 'outcome.json')['complete'])

    def test_all_twelve_proofs_are_required_for_the_current_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proofs = [self.proof(family, name) for family in SHARDS.FAMILIES for name in SHARDS.SHARDS]
            for index, proof in enumerate(proofs):
                folder = root / str(index);folder.mkdir();(folder / 'proof.json').write_text(json.dumps(proof))
            self.assertEqual(SHARDS.aggregate(root, self.source)['journeysPerFamily'], 53)
            path = root / '0/proof.json'
            for key, value in [('complete', False), ('shutdown', False), ('revision', 'other'),
                               ('sourceFingerprint', 'other'), ('family', 'other')]:
                bad = copy.deepcopy(proofs[0]);bad[key] = value;path.write_text(json.dumps(bad))
                with self.subTest(key=key), self.assertRaises(ValueError): SHARDS.aggregate(root, self.source)
            path.unlink()
            with self.assertRaises(ValueError): SHARDS.aggregate(root, self.source)

    def test_wrong_runtime_substituted_tests_and_missing_reset_are_rejected(self):
        for mutation in ('runtime', 'test', 'reset', 'duplicate-device', 'time'):
            proof = self.proof('ipad', 'native')
            if mutation == 'runtime': proof['device']['osVersion'] = '26.5'
            elif mutation == 'test': proof['phases'][1]['tests'] = ['CodexBarIOSUITests/Other/testSubstituted']
            elif mutation == 'reset': proof['phases'].pop()
            elif mutation == 'duplicate-device': proof['device']['family'] = 'iphone'
            else: proof['phases'][0]['started'] = '2026-10-24T11:00:00+00:00'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                SHARDS.validate_proof(proof, self.source, 'ipad', 'native', self.plan['native'])

    def test_automatic_job_and_workload_inventory_remain_unchanged(self):
        workflow = (SCRIPTS.parent / '.github/workflows/ci.yml').read_text()
        from scripts.tests.test_ci_policy import job_block, workflow_trigger_keys
        self.assertEqual(workflow_trigger_keys(workflow), {'pull_request', 'workflow_dispatch'})
        lint = job_block(workflow, 'swiftlint')
        self.assertIn('timeout-minutes: 10', lint)
        self.assertNotIn('ui_release_shards', lint)
        self.assertEqual(workflow.count('test_ci_policy.py'), 1)
        worker = job_block(workflow, 'ios-ui-families')
        self.assertIn("github.event_name == 'workflow_dispatch'", worker)
        self.assertIn('timeout-minutes: 90', worker)
        self.assertIn('shard: [' + ', '.join(SHARDS.SHARDS) + ']', worker)
        self.assertIn('verify-release-toolchain.py', worker)
        self.assertIn('ui_release_shards.py aggregate', job_block(workflow, 'ios-ui-tests'))

    def test_manual_notifier_permission_and_full_workflow_scope(self):
        workflow = (SCRIPTS.parent / '.github/workflows/ci.yml').read_text()
        from scripts.tests.test_ci_policy import job_block
        aggregate = job_block(workflow, 'ios-ui-tests')
        marker = '      - name: Notify Chief of manual UI aggregate outcome\n'
        self.assertEqual(workflow.count(marker), 1)
        self.assertEqual(workflow.count('pull-requests: write'), 1)
        self.assertNotIn('issues: write', workflow)
        self.assertIn('      pull-requests: write\n', aggregate)
        notifier = aggregate[aggregate.index(marker):]
        self.assertIn('always() && !cancelled()', notifier)
        self.assertIn("github.ref != 'refs/heads/main'", notifier)
        self.assertIn('          retries: 0\n', notifier)
        self.assertIn('          debug: false\n', notifier)
        script = notifier.split('          script: |\n', 1)[1]
        script = '\n'.join(line[12:] for line in script.splitlines() if line.startswith('            ')) + '\n'
        self.assertEqual(hashlib.sha256(script.encode()).hexdigest(),
                         '4f299b77c869f5674c5fc63a9af4cd208a0ac17c39a43b8b88b8538763229ead')
        # Removing the approved step and its job-level grant must recover the
        # pre-relay workflow plus the explicit manual cost-only mode. The separate
        # manual cost controls recover the complete older workflow byte-for-byte.
        restored = workflow.replace(notifier, '').replace('      pull-requests: write\n', '', 1)
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(),
                         '6d5b13d1d4ecd0155cb77e7cea1a956b58fd3dd4a17a3c09253366b9a7f015b0')


if __name__ == '__main__':
    unittest.main()
