import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
UI_RUNNER = REPOSITORY_ROOT / "scripts" / "run-ui-tests.sh"


def job_block(workflow: str, job_id: str) -> str:
    pattern = re.compile(
        rf"^  {re.escape(job_id)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(workflow)
    if match is None:
        raise AssertionError(f"Missing workflow job: {job_id}")
    return match.group(0)


def workflow_trigger_keys(workflow: str) -> set[str]:
    # The supported workflow shape is a block mapping. Reject alternative YAML
    # shapes rather than silently overlooking an automatic event.
    match = re.search(r"^on:\n(.*?)(?=^[^\s#]|\Z)", workflow, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError("Workflow triggers must be an explicit on block mapping")
    keys = []
    for line in match.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("  ") and not line.startswith("   "):
            event = re.fullmatch(r"  ([a-z_]+):(?:\s.*)?", line)
            if event is None:
                raise AssertionError(f"Unsupported workflow event declaration: {line}")
            keys.append(event.group(1))
    if len(keys) != len(set(keys)):
        raise AssertionError("Duplicate workflow event declarations")
    return set(keys)


class CITriggerPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        cls.ui_runner = UI_RUNNER.read_text(encoding="utf-8")

    def test_ci_supports_automatic_and_manual_runs(self) -> None:
        allowed = {"pull_request", "workflow_dispatch"}
        self.assertEqual(workflow_trigger_keys(self.workflow), allowed)
        for event in ("push: {}", "schedule: []", "merge_group:"):
            altered = self.workflow.replace("on:\n", f"on:\n  {event}\n", 1)
            self.assertNotEqual(workflow_trigger_keys(altered), allowed, event)
        for declaration in ("on: [pull_request, push]", "on: {pull_request: {}, push: {}}"):
            altered = self.workflow.replace("on:", declaration, 1)
            with self.assertRaises(AssertionError):
                workflow_trigger_keys(altered)

    def test_native_jobs_are_dispatch_only_and_keep_their_workloads(self) -> None:
        for job_id in ("strict-concurrency", "ios-tests", "watch-tests", "smoke-tests"):
            # Gate-only branch (#517): quality jobs are skipped in the ui-only manual mode.
            self.assertIn("    if: ${{ github.event_name == 'workflow_dispatch' && "
                          "inputs.ui_validation_mode != 'ui-only' }}\n", job_block(self.workflow, job_id))
        lint_job = job_block(self.workflow, "swiftlint")
        smoke_job = job_block(self.workflow, "smoke-tests")
        self.assertIn("swiftlint lint", lint_job)
        self.assertIn("test_ci_policy.py", lint_job)
        self.assertNotIn("test_ci_policy.py", smoke_job)
        self.assertEqual(self.workflow.count("test_ci_policy.py"), 1)
        self.assertIn("check-strict-concurrency.sh", job_block(self.workflow, "strict-concurrency"))
        self.assertIn("Enforce watchOS function risk baseline", job_block(self.workflow, "watch-tests"))
        self.assertIn("swift run CodexBarIOSSmokeTests", smoke_job)
        ios_job = job_block(self.workflow, "ios-tests")
        self.assertIn("    name: iOS tests\n", ios_job)
        self.assertIn("    timeout-minutes: 45\n", ios_job)
        self.assertIn("Run iOS unit tests", ios_job)
        self.assertIn("Enforce iOS function risk baseline", ios_job)
        self.assertNotIn("UI journeys", ios_job)
        self.assertNotIn("run-ui-tests.sh", ios_job)

    def test_ui_job_runs_only_after_a_successful_manual_gate(self) -> None:
        ui_job = job_block(self.workflow, "ios-ui-families")
        self.assertIn(
            "    if: ${{ github.event_name == 'workflow_dispatch' && "
            "inputs.ui_validation_mode != 'account-menu-comparison' && !cancelled() && "
            "!contains(needs.*.result, 'failure') }}\n",
            ui_job,
        )
        for required_job in (
            "swiftlint",
            "strict-concurrency",
            "ios-tests",
            "watch-tests",
            "smoke-tests",
        ):
            self.assertIn(f"      - {required_job}\n", ui_job)
        self.assertIn('run: ./scripts/run-ui-tests.sh "${{ matrix.family }}"', ui_job)
        self.assertIn("family: [iphone, ipad]", ui_job)
        self.assertIn("fail-fast: false", ui_job)
        self.assertIn("retention-days: 14", ui_job)
        aggregate = job_block(self.workflow, "ios-ui-tests")
        self.assertIn("always() && github.event_name == 'workflow_dispatch'", aggregate)
        self.assertIn('if [[ "$UI_FAMILIES_RESULT" != success ]]', aggregate)

    def test_ui_runner_requires_all_twenty_nine_journeys(self) -> None:
        for assertion in (
            ".totalTestCount == 29",
            ".passedTests == 29",
            ".failedTests == 0",
            ".skippedTests == 0",
            ".expectedFailures == 0",
        ):
            self.assertIn(assertion, self.ui_runner)


if __name__ == "__main__":
    unittest.main()
