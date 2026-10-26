"""Manual-only identity/failure controls for the actual cost preparation script."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('cost', ROOT / 'prepare-automatic-cost.py')
COST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COST)
WORKFLOW = (ROOT.parent / '.github/workflows/ci.yml').read_text()


class CostControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = self.folder / 'repo'
        self.repo.mkdir()
        self.previous = Path.cwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, self.previous)
        self.real_command = COST.command
        for args in (('init', '-q'), ('config', 'user.name', 'Fixture'),
                     ('config', 'user.email', 'fixture@example.invalid')):
            self.git(*args)
        path = self.repo / '.github/workflows/ci.yml'
        path.parent.mkdir(parents=True)
        # Same effective automatic job, before the manual guard was introduced.
        original = COST.automatic_job(WORKFLOW)
        modified = WORKFLOW[WORKFLOW.index('  swiftlint:\n'):WORKFLOW.index('  strict-concurrency:\n')]
        self.before = WORKFLOW.replace(modified, original)
        path.write_text(self.before)
        self.git('add', '.')
        self.git('commit', '-qm', 'baseline')
        self.base = self.git('rev-parse', 'HEAD')
        path.write_text(WORKFLOW)
        (self.repo / 'candidate.txt').write_text('candidate source\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'candidate')
        self.head = self.git('rev-parse', 'HEAD')
        self.env = dict(
            GITHUB_ACTIONS='true', GITHUB_EVENT_NAME='workflow_dispatch',
            GITHUB_REPOSITORY='hemsoft-dev/codexbar-ios', GITHUB_SHA=self.head,
            AUTOMATIC_COST_MODE='automatic-cost', AUTOMATIC_COST_ROLE='baseline',
            AUTOMATIC_COST_BASE=self.base, AUTOMATIC_COST_IMAGE='20261021.0445.8',
            AUTOMATIC_COST_TOOLCHAIN='', ImageVersion='20261021.0445.8', ImageOS='macos26-arm64',
            DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', RUNNER_TEMP=str(self.folder),
        )
        self.calls = []

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True, stderr=subprocess.PIPE).strip()

    def command(self, *args):
        self.calls.append(args)
        if args == ('xcodebuild', '-version'):
            return 'Xcode fixture\nBuild version fixture'
        if args == ('xcrun', 'swift', '--version'):
            return 'Swift fixture\nTarget: arm64-apple-macosx'
        return self.real_command(*args)

    def run_control(self):
        with patch.object(COST, 'command', self.command), contextlib.redirect_stdout(io.StringIO()):
            return COST.prepare(self.env, self.folder / 'receipt.json')

    def test_real_git_baseline_then_candidate_bind_receipts_and_toolchain(self):
        baseline = self.run_control()
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.base)
        self.assertEqual(baseline['measuredSource'], self.base)
        self.git('checkout', '--detach', self.head)
        self.env.update(AUTOMATIC_COST_ROLE='candidate', AUTOMATIC_COST_TOOLCHAIN=baseline['toolchainSHA256'])
        candidate = self.run_control()
        self.assertEqual(candidate['measuredSource'], self.head)
        self.assertEqual(candidate['toolchainSHA256'], baseline['toolchainSHA256'])
        self.assertEqual(candidate['automaticJobSHA256'], hashlib.sha256(COST.automatic_job(WORKFLOW).encode()).hexdigest())
        self.assertEqual(json.loads((self.folder / 'receipt.json').read_text()), candidate)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_wrong_image_refused_before_any_command_or_source_switch(self):
        self.env['ImageVersion'] = '20261013.0424.1'
        with self.assertRaisesRegex(COST.Refused, 'image-mismatch'):
            self.run_control()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)

    def test_wrong_context_and_invalid_sources_never_run_commands(self):
        for key, value in (('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_REPOSITORY', 'other/repo'),
                           ('AUTOMATIC_COST_ROLE', 'other'), ('AUTOMATIC_COST_BASE', 'main; echo unsafe')):
            with self.subTest(key=key), patch.dict(self.env, {key: value}):
                with self.assertRaises(COST.Refused):
                    self.run_control()
                self.assertEqual(self.calls, [])

    def test_dirty_or_wrong_checkout_refused(self):
        (self.repo / 'untracked').write_text('owned test')
        with self.assertRaisesRegex(COST.Refused, 'dirty-checkout'):
            self.run_control()
        (self.repo / 'untracked').unlink()
        self.git('checkout', '--detach', self.base)
        with self.assertRaisesRegex(COST.Refused, 'wrong-checkout'):
            self.run_control()

    def test_missing_or_different_toolchain_does_not_switch_source(self):
        self.env['AUTOMATIC_COST_ROLE'] = 'candidate'
        for value, expected in (('', 'missing-baseline-toolchain'), ('a' * 64, 'toolchain-mismatch')):
            self.env['AUTOMATIC_COST_TOOLCHAIN'] = value
            with self.assertRaisesRegex(COST.Refused, expected):
                self.run_control()
            self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
            self.assertFalse((self.folder / 'receipt.json').exists())

    def test_changed_automatic_command_fails_before_workload(self):
        path = self.repo / '.github/workflows/ci.yml'
        path.write_text(WORKFLOW.replace('--reporter github-actions-logging', '--reporter json'))
        self.git('add', '.')
        self.git('commit', '-qm', 'different automatic workload')
        self.head = self.git('rev-parse', 'HEAD')
        self.env['GITHUB_SHA'] = self.head
        with self.assertRaisesRegex(COST.Refused, 'automatic-workload-changed'):
            self.run_control()
        self.assertNotIn(('xcodebuild', '-version'), self.calls)

    def test_normalizer_cannot_hide_an_extra_automatic_step(self):
        injected = WORKFLOW.replace(
            COST.MANUAL_GUARD, COST.MANUAL_GUARD + "      - name: Hidden extra work\n        run: echo extra\n\n",
        )
        self.assertNotEqual(COST.automatic_job(injected), COST.automatic_job(WORKFLOW))
        unconditional = WORKFLOW.replace(
            "if: ${{ github.event_name == 'workflow_dispatch' && inputs.ui_validation_mode == 'automatic-cost' }}",
            "if: ${{ always() }}", 1,
        )
        self.assertNotEqual(COST.automatic_job(unconditional), COST.automatic_job(WORKFLOW))

    def test_receipt_failure_cannot_be_a_pass(self):
        with patch.object(Path, 'write_text', side_effect=PermissionError('fixture')):
            with self.assertRaises(PermissionError):
                self.run_control()
        self.assertFalse((self.folder / 'receipt.json').exists())

    def test_command_timeout_is_not_retried(self):
        with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 10)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                COST.command('git', 'status')
        self.assertEqual(run.call_count, 1)

    def test_removing_only_cost_mode_restores_complete_prior_workflow(self):
        restored = WORKFLOW.replace(
            'Full release gate, focused account-menu diagnosis, or automatic-cost control',
            'Full release gate or focused native account-menu diagnosis',
        ).replace('          - automatic-cost\n', '', 1).replace(
            'Exact ancestor SHA for manual comparison modes', 'Exact ancestor SHA for account-menu comparison only',
        )
        begin = restored.index('\n      cost_source_role:')
        end = restored.index('\npermissions:', begin)
        restored = restored[:begin] + restored[end:]
        restored = restored.replace(
            "          fetch-depth: ${{ inputs.ui_validation_mode == 'automatic-cost' && '0' || '1' }}\n", '', 1,
        ).replace(COST.MANUAL_GUARD, '', 1).replace(" && inputs.ui_validation_mode != 'automatic-cost'", '')
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(),
                         'a42e96c0bb86bf3d840a8067dabf696c137d5b8717e8664a3b1b59623e19df89')

    def test_workflow_keeps_normal_automatic_steps_and_manual_full_gates(self):
        automatic = COST.automatic_job(WORKFLOW)
        self.assertEqual(automatic.count('      - '), 3)
        self.assertIn('timeout-minutes: 10', automatic)
        self.assertIn('runs-on: macos-26', automatic)
        self.assertIn("&& '0' || '1'", WORKFLOW)
        self.assertEqual(WORKFLOW.count("if: ${{ github.event_name == 'workflow_dispatch' && inputs.ui_validation_mode != 'automatic-cost' }}"), 4)
        self.assertIn("inputs.ui_validation_mode != 'account-menu-comparison' && inputs.ui_validation_mode != 'automatic-cost' && success()", WORKFLOW)
        self.assertIn('shard: [original-1, original-2, original-3, supplemental, synthetic, native]', WORKFLOW)
        self.assertIn('timeout-minutes: 90', WORKFLOW)
        self.assertEqual(WORKFLOW.count('test_ci_policy.py'), 1)


if __name__ == '__main__':
    unittest.main()
