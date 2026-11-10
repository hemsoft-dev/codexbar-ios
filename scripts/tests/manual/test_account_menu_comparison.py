import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "compare-account-menu.py"
SPEC = importlib.util.spec_from_file_location("account_menu_comparison", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AccountMenuComparisonTests(unittest.TestCase):
    def summary(self, **updates):
        result = dict(result="Passed", totalTestCount=1, passedTests=1, failedTests=0,
                      skippedTests=0, expectedFailures=0)
        result.update(updates)
        return result

    def test_only_one_complete_passing_journey_is_accepted(self):
        self.assertTrue(MODULE.passed_one(self.summary()))
        for changes in [dict(totalTestCount=0, passedTests=0), dict(totalTestCount=2, passedTests=2),
                        dict(skippedTests=1), dict(expectedFailures=1), dict(failedTests=1), dict(result="Failed")]:
            self.assertFalse(MODULE.passed_one(self.summary(**changes)))
        incomplete = self.summary()
        del incomplete["expectedFailures"]
        self.assertFalse(MODULE.passed_one(incomplete))
        self.assertEqual(MODULE.classify_baseline(65, self.summary()), "unclassified-failure")

    def test_baseline_failure_must_be_the_original_menu_assertion(self):
        failure = dict(failureText='failed - Control is unreachable at accessibility text size: "Configure account Fixture" Button.',
                       testIdentifierString="SettingsEvidenceUITests/testRetiredGoogleUpgradeEvidence()")
        summary = self.summary(result="Failed", passedTests=0, failedTests=1, testFailures=[failure])
        self.assertEqual(MODULE.classify_baseline(65, summary), "known-menu-failure")
        self.assertEqual(MODULE.classify_baseline(0, self.summary()), "passed")
        for changes in [dict(failureText="Simulator failed to launch"), dict(failureText="Circular ring is not selected"),
                        dict(testIdentifierString="OtherJourney"), dict(failureText="Infrastructure failed\nConfigure account Fixture")]:
            altered = dict(failure, **changes)
            self.assertEqual(MODULE.classify_baseline(65, dict(summary, testFailures=[altered])), "unclassified-failure")
        for changes in [dict(skippedTests=1), dict(expectedFailures=1), dict(totalTestCount=0), dict(testFailures=[])]:
            self.assertEqual(MODULE.classify_baseline(65, dict(summary, **changes)), "unclassified-failure")

    def test_device_selection_excludes_unavailable_and_newer_runtimes(self):
        runtimes = [dict(identifier="com.apple.CoreSimulator.SimRuntime.iOS-26-5", version="26.5", isAvailable=True),
                    dict(identifier="com.apple.CoreSimulator.SimRuntime.iOS-27-0", version="27.0", isAvailable=True)]
        simulators = dict(runtimes=runtimes, devices={runtimes[0]["identifier"]: [
            dict(name="iPad Pro", udid="pad", isAvailable=True), dict(name="iPhone 17", udid="phone", isAvailable=True),
            dict(name="iPhone 18", udid="unavailable", isAvailable=False)],
            runtimes[1]["identifier"]: [dict(name="iPhone 19", udid="newer", isAvailable=True)]})
        runtime, phone = MODULE.choose_device(simulators, "26.6", "iPhone")
        self.assertEqual(phone["udid"], "phone")
        self.assertEqual(runtime["version"], "26.5")
        self.assertEqual(MODULE.choose_device(simulators, "26.6", "iPad")[1]["udid"], "pad")
        with self.assertRaises(RuntimeError):
            MODULE.choose_device(simulators, "26.4", "iPhone")


if __name__ == "__main__":
    unittest.main()
