"""Exercise the performance gate's failure policy without timing unit tests."""
import copy
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import unittest
import tempfile
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "usage-history-performance/run.py"
SPEC = importlib.util.spec_from_file_location("history_performance", SCRIPT)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
POLICY = json.loads(SCRIPT.with_name("baseline.json").read_text())
REPLAY_SPEC = importlib.util.spec_from_file_location("history_replay", SCRIPT.with_name("replay.py"))
REPLAY = importlib.util.module_from_spec(REPLAY_SPEC)
with mock.patch.dict(sys.modules, {"run": GATE}):
    REPLAY_SPEC.loader.exec_module(REPLAY)


def report():
    return dict(configuration="release", fixtureVersion=1, timeZone="UTC", warmupBatches=2, qosClass=25,
                measuredBatches=5, seriesIterationsPerBatch=5, deterministicHashing=True, hashProbe=42,
                scenarios=[dict(accounts=accounts, recordMilliseconds=[100, 100, 10, 10, 10, 10, 10],
                                seriesMilliseconds=[100, 100, 2, 2, 2, 2, 2], seriesPointCount=accounts * 329 * 35,
                                recordThreadCPUMilliseconds=[1] * 7, seriesThreadCPUMilliseconds=[1] * 7,
                                retainedStates=[dict(snapshots=accounts * 240, dailySnapshots=accounts * 180,
                                                     serializedBytes=accounts * 220000) for _ in range(47)])
                           for accounts in (1, 10, 25)])


class BenchmarkSchedulingTests(unittest.TestCase):
    def test_accepts_observed_user_initiated_class(self):
        GATE.validate_scheduling(report())

    def test_rejects_missing_scheduling_evidence(self):
        value = report()
        del value["qosClass"]
        with self.assertRaises(ValueError):
            GATE.validate_scheduling(value)

    def test_rejects_other_classes_and_malformed_values(self):
        for value in (17, 9, 33, None, True, "25", 25.0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                GATE.validate_scheduling(dict(report(), qosClass=value))

    def test_diagnostic_write_error_preserves_original_process_failure(self):
        native_run = subprocess.run
        failures = []
        def observe(*args, **kwargs):
            try:
                return native_run(*args, **kwargs)
            except subprocess.CalledProcessError as error:
                failures.append(error)
                raise
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "failed-after-machine.json").mkdir()
            with mock.patch.object(GATE.subprocess, "run", side_effect=observe):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    GATE.measure(Path("/usr/bin/false"), output, "failed")
            self.assertIs(caught.exception, failures[0])
            self.assertTrue((output / "failed-before-machine.json").is_file())
            self.assertTrue((output / "failed.json").is_file())

    def test_live_measurement_keeps_and_rejects_wrong_scheduling_report(self):
        value = dict(report(), qosClass=17)
        def process(*args, **kwargs):
            kwargs["stdout"].write(json.dumps(value))
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with mock.patch.object(GATE, "machine_snapshot"), mock.patch.object(GATE.subprocess, "run", side_effect=process):
                with self.assertRaisesRegex(ValueError, "user-initiated"):
                    GATE.measure(Path("unused-binary"), output, "legacy")
            self.assertEqual(json.loads((output / "legacy.json").read_text()), value)
            self.assertTrue((output / "legacy.stderr.log").exists())


class BenchmarkCPUDiagnosticTests(unittest.TestCase):
    def test_accepts_real_shape_without_changing_wall_clock_verdict(self):
        GATE.validate_cpu_diagnostics(report())
        pairs = [{"reference": report(), "candidate": report()} for _ in range(3)]
        before = GATE.evaluate(pairs, POLICY)
        for pair in pairs:
            pair["candidate"]["scenarios"][0]["recordThreadCPUMilliseconds"] = [999] * 7
        self.assertEqual(GATE.evaluate(pairs, POLICY), before)

    def test_rejects_missing_or_malformed_cpu_observations(self):
        for value in (None, [], [1] * 6, [1] * 8, [0] * 7, [-1] * 7, [True] * 7, [float("nan")] * 7):
            with self.subTest(value=value), self.assertRaises(ValueError):
                sample = report()
                sample["scenarios"][0]["recordThreadCPUMilliseconds"] = value
                GATE.validate_cpu_diagnostics(sample)


class BenchmarkHashingTests(unittest.TestCase):
    def test_accepts_matching_runtime_probes(self):
        GATE.validate_hash_consistency([{"reference": report(), "candidate": report()} for _ in range(3)])

    def test_rejects_randomized_or_missing_runtime_evidence(self):
        missing_setting = report()
        del missing_setting["deterministicHashing"]
        missing_probe = report()
        del missing_probe["hashProbe"]
        for value in (missing_setting, missing_probe, dict(report(), deterministicHashing=False), dict(report(), hashProbe=True)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                GATE.validate_hashing(value)

    def test_rejects_runtime_probe_disagreement(self):
        pairs = [{"reference": report(), "candidate": report()} for _ in range(3)]
        pairs[-1]["candidate"]["hashProbe"] = 99
        with self.assertRaisesRegex(ValueError, "probes differ"):
            GATE.validate_hash_consistency(pairs)

    def test_live_process_pins_hashing_without_changing_build_environment(self):
        def process(*args, **kwargs):
            self.assertEqual(kwargs["env"]["SWIFT_DETERMINISTIC_HASHING"], "1")
            self.assertIsNot(kwargs["env"], GATE.ENV)
            kwargs["stdout"].write(json.dumps(report()))
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(GATE, "machine_snapshot"), mock.patch.object(GATE.subprocess, "run", side_effect=process):
                GATE.measure(Path("unused-binary"), Path(temporary), "hashing")


class HostAdmissionTests(unittest.TestCase):
    def exercise(self, samples):
        clock = [0.0]
        seen = []
        def sample(**kwargs):
            value = samples[min(len(seen), len(samples) - 1)]
            seen.append(value)
            return value
        def sleep(seconds):
            clock[0] += seconds
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            try:
                GATE.admit_quiet_host(output, snapshot=sample, sleep=sleep, monotonic=lambda: clock[0])
                failure = None
            except ValueError as error:
                failure = str(error)
            receipt = json.loads((output / "host-admission.json").read_text())
            return failure, receipt, clock[0]

    def test_requires_nine_consecutive_quiet_snapshots_over_two_minutes(self):
        failure, receipt, elapsed = self.exercise([dict(logicalCPUs=3, loadAverage=[2, 4, 5], busyProcesses=[])])
        self.assertIsNone(failure)
        self.assertTrue(receipt["passed"])
        self.assertEqual(len(receipt["samples"]), 9)
        self.assertEqual(elapsed, 120)

    def test_startup_load_and_compiler_activity_reset_admission_without_discarding_samples(self):
        quiet = dict(logicalCPUs=3, loadAverage=[2, 4, 5], busyProcesses=[])
        busy = dict(logicalCPUs=3, loadAverage=[4, 4, 5], busyProcesses=[])
        compiler = dict(logicalCPUs=3, loadAverage=[2, 4, 5], busyProcesses=["swift-frontend"])
        failure, receipt, elapsed = self.exercise([quiet, busy, quiet, compiler] + [quiet] * 9)
        self.assertIsNone(failure)
        self.assertEqual(len(receipt["samples"]), 13)
        self.assertEqual(elapsed, 180)
        self.assertEqual(receipt["samples"][1]["quiet"], False)
        self.assertEqual(receipt["samples"][3]["quiet"], False)

    def test_busy_host_fails_within_fixed_budget_and_keeps_every_probe(self):
        failure, receipt, elapsed = self.exercise([dict(logicalCPUs=3, loadAverage=[4, 4, 5], busyProcesses=[])])
        self.assertIn("quiet host", failure)
        self.assertFalse(receipt["passed"])
        self.assertLessEqual(elapsed, 420)
        self.assertGreater(len(receipt["samples"]), 9)

    def test_admission_receipt_failure_preserves_primary_probe_error(self):
        primary = RuntimeError("probe unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(Path, "write_text", side_effect=OSError("write unavailable")):
                with self.assertRaises(RuntimeError) as caught:
                    GATE.admit_quiet_host(Path(temporary), snapshot=mock.Mock(side_effect=primary))
        self.assertIs(caught.exception, primary)

    def test_admission_receipt_write_failure_cannot_pass(self):
        clock = [0.0]
        def sleep(seconds):
            clock[0] += seconds
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(Path, "write_text", side_effect=OSError("write unavailable")):
                with self.assertRaises(OSError):
                    GATE.admit_quiet_host(Path(temporary),
                                         snapshot=lambda **kwargs: dict(logicalCPUs=3, loadAverage=[1, 2, 3], busyProcesses=[]),
                                         sleep=sleep, monotonic=lambda: clock[0])

    def test_process_probe_rejects_compiler_and_simulator_work(self):
        result = subprocess.CompletedProcess([], 0, " 12.0 /usr/bin/swift-frontend\n 14.0 /x/Simulator.app/Contents/MacOS/Simulator\n"
                                             " 20.0 /Library/Developer/CoreSimulator/Devices/fixture/CodexBarIOS.app/CodexBarIOS\n"
                                             " 15.0 /usr/libexec/testmanagerd\n 1.0 /usr/bin/clang\n"
                                             " 18.0 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/"
                                             "XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/"
                                             "com.apple.CoreSimulator.CoreSimulatorService\n", "")
        with mock.patch.object(GATE.subprocess, "run", return_value=result):
            observation = GATE.admission_snapshot()
        self.assertEqual([item["cpu"] for item in observation["busyProcesses"]], [12, 14, 20, 15, 18])

    def test_empty_process_probe_cannot_qualify_as_quiet(self):
        result = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(GATE.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "missing process"):
                GATE.admission_snapshot()

    def test_failed_admission_stops_actual_runner_before_any_measurement(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "run"
            with mock.patch.object(sys, "argv", [str(SCRIPT), "--output", str(output)]), \
                    mock.patch.object(GATE, "command", return_value=""), \
                    mock.patch.object(GATE, "reference_tree"), \
                    mock.patch.object(GATE, "build", return_value=Path("unused")) as build, \
                    mock.patch.object(GATE, "admit_quiet_host", side_effect=ValueError("host busy")), \
                    mock.patch.object(GATE, "measure") as measure:
                with self.assertRaisesRegex(ValueError, "host busy"):
                    GATE.main()
            self.assertEqual(build.call_count, 2)
            measure.assert_not_called()
            self.assertFalse((output / "result.json").exists())

    def test_probe_budget_is_capped_by_remaining_deadline_and_no_probe_starts_after_it(self):
        clock, timeouts = [0.0], []
        def sample(*, timeout=5):
            timeouts.append(timeout)
            clock[0] += min(1, timeout)
            return dict(logicalCPUs=3, loadAverage=[4, 4, 5], busyProcesses=[])
        def sleep(seconds):
            clock[0] += seconds
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaisesRegex(ValueError, "quiet host"):
                GATE.admit_quiet_host(output, snapshot=sample, sleep=sleep, monotonic=lambda: clock[0])
            receipt = json.loads((output / "host-admission.json").read_text())
        self.assertLess(timeouts[-1], 5)
        self.assertTrue(all(0 < timeout <= 5 for timeout in timeouts))
        self.assertEqual(clock[0], 420)
        self.assertLessEqual(receipt["elapsedSeconds"], 420)
        self.assertFalse(receipt["passed"])

    def test_actual_process_probe_receives_the_remaining_timeout(self):
        result = subprocess.CompletedProcess([], 0, " 0.1 /usr/bin/ps\n", "")
        with mock.patch.object(GATE.subprocess, "run", return_value=result) as run:
            GATE.admission_snapshot(timeout=0.125)
        self.assertEqual(run.call_args.kwargs["timeout"], 0.125)

    def test_runtime_child_processes_prevent_admission_even_below_the_load_limit(self):
        result = subprocess.CompletedProcess([], 0,
            " 25.0 /Library/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/SpringBoard\n"
            " 11.0 /Library/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/mobileassetd\n", "")
        with mock.patch.object(GATE.subprocess, "run", return_value=result), \
                mock.patch.object(GATE.os, "cpu_count", return_value=3), \
                mock.patch.object(GATE.os, "getloadavg", return_value=(1, 1, 1)):
            observation = GATE.admission_snapshot()
        self.assertEqual(len(observation["busyProcesses"]), 2)
        failure, receipt, _ = self.exercise([observation])
        self.assertIsNotNone(failure)
        self.assertFalse(receipt["passed"])

    def test_serializable_invalid_observations_are_retained_exactly(self):
        observations = [None, False, 0, "", [],
                        dict(logicalCPUs=None, loadAverage=[1, 2, 3], busyProcesses=[]),
                        dict(logicalCPUs=3, loadAverage=[-1, 2, 3], busyProcesses=[])]
        for observation in observations:
            with self.subTest(observation=observation):
                failure, receipt, _ = self.exercise([observation])
                self.assertIsNotNone(failure)
                self.assertFalse(receipt["passed"])
                self.assertEqual(len(receipt["samples"]), 1)
                self.assertEqual(receipt["samples"][0]["observation"], observation)
                self.assertFalse(receipt["samples"][0]["valid"])

    def test_invalid_cpu_or_load_fails_closed(self):
        for cpus, load in [(False, 1), (0, 1), (None, 1), (3, float("nan")), (3, -1)]:
            with self.subTest(cpus=cpus, load=load):
                failure, receipt, _ = self.exercise([dict(logicalCPUs=cpus, loadAverage=[load, 1, 1], busyProcesses=[])])
                self.assertIsNotNone(failure)
                self.assertFalse(receipt["passed"])
                self.assertEqual(len(receipt["samples"]), 1)


class PerformanceGateTests(unittest.TestCase):
    def setUp(self):
        self.runs = [dict(reference=report(), candidate=report()) for _ in range(3)]

    def test_existing_results_cannot_masquerade_as_a_new_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "run"
            GATE.prepare_output(output)
            (output / "result.json").write_text('{"passed": false, "findings": ["REGRESSION"]}')
            with self.assertRaises(ValueError):
                GATE.prepare_output(output)
            self.assertTrue((output / "result.json").exists())

    def test_failed_process_and_invalid_json_keep_raw_evidence(self):
        for exit_code, error in ((7, subprocess.CalledProcessError), (0, json.JSONDecodeError)):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                binary = output / "broken-benchmark"
                binary.write_text(f"#!{sys.executable}\nimport sys\nprint('partial report')\n"
                                  f"print('fixture failure', file=sys.stderr)\nsys.exit({exit_code})\n")
                binary.chmod(0o700)
                with mock.patch.object(GATE, "machine_snapshot") as snapshot:
                    with self.assertRaises(error):
                        GATE.measure(binary, output, "1-candidate")
                    self.assertEqual(snapshot.call_args_list, [mock.call(output, "1-candidate-before"),
                                                               mock.call(output, "1-candidate-after")])
                self.assertEqual((output / "1-candidate.json").read_text(), "partial report\n")
                self.assertEqual((output / "1-candidate.stderr.log").read_text(), "fixture failure\n")
                self.assertFalse((output / "result.json").exists())

    def test_unavailable_machine_probes_remain_visible_diagnostics(self):
        errors = (OSError("probe unavailable"),
                  UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte"))
        for error in errors:
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                with mock.patch.object(GATE.subprocess, "run", side_effect=error):
                    GATE.machine_snapshot(output, "before")
                snapshot = json.loads((output / "before-machine.json").read_text())
                self.assertIn("capturedAt", snapshot)
                for probe in ("thermal", "memory", "processes"):
                    self.assertEqual(snapshot[probe], {"error": str(error)})

    def test_committed_recordings_expand_and_replay(self):
        for name, expected_pass in (("calibration", True), ("slowdown-proof", False)):
            with self.subTest(name=name):
                recording = json.loads(SCRIPT.with_name(f"{name}.json").read_text())
                original = copy.deepcopy(recording)
                expanded = REPLAY.expand_runs(recording)
                self.assertEqual(recording, original)
                states = expanded[0]["candidate"]["scenarios"][0]["retainedStates"]
                self.assertEqual(len(states), 47)
                self.assertEqual(states[0], states[-1])
                self.assertIsNot(states[0], states[-1])
                result = GATE.evaluate(expanded, POLICY)
                self.assertEqual(result["passed"], expected_pass)
                self.assertFalse(any("INCONCLUSIVE" in item for item in result["findings"]))
                if not expected_pass:
                    for accounts in (1, 10, 25):
                        self.assertTrue(any(f"REGRESSION {accounts} accounts recordMilliseconds" in item for item in result["findings"]))

    def test_repeatability_study_rejects_missing_or_altered_evidence(self):
        study = json.loads(SCRIPT.with_name("repeatability-study.json").read_text())
        results = REPLAY.replay_study(study, POLICY)
        self.assertEqual(len(results), len(study["experiments"]))
        self.assertTrue(any(result["passed"] for _, result in results))
        self.assertTrue(any(not result["passed"] for _, result in results))
        equivalent = copy.deepcopy(study)
        equivalent["experiments"][0]["result"]["timings"][0]["medianRatio"] += 1e-13
        self.assertEqual(REPLAY.replay_study(equivalent, POLICY), results)

        def change_warmup(value):
            samples = value["experiments"][0]["runs"][0]["reference"]["scenarios"][0]["recordMilliseconds"]
            samples[0] = 9999

        def remove_trial_and_declaration(value):
            value["experiments"].pop(0)
            value["experimentNames"].pop(0)

        mutations = [
            lambda value: value["experiments"].clear(),
            lambda value: value["experiments"].pop(),
            lambda value: value["experiments"].append(copy.deepcopy(value["experiments"][0])),
            lambda value: value["experiments"][0]["result"].update(
                passed=not value["experiments"][0]["result"]["passed"]),
            lambda value: value["experiments"][0]["result"]["timings"][0].update(medianRatio=0),
            lambda value: value["experiments"][0]["runs"].pop(),
            change_warmup,
            remove_trial_and_declaration,
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                invalid = copy.deepcopy(study)
                mutate(invalid)
                with self.assertRaises(ValueError):
                    REPLAY.replay_study(invalid, POLICY)

    def test_clean_study_rejects_dirty_or_unmatched_inputs(self):
        original = json.loads(SCRIPT.with_name("repeatability-study.json").read_text())
        for field, value in (("candidateDirty", True), ("candidateRevision", "unknown")):
            study = copy.deepcopy(original)
            study["experiments"][-1]["metadata"][field] = value
            with self.assertRaises(ValueError):
                REPLAY.replay_study(study, POLICY)
        for field in ("status", "productionDiff", "patchSHA256"):
            for value in ("unverified", None, False, 0, [], {}):
                study = copy.deepcopy(original)
                study["cleanInputProof"][field] = value
                with self.assertRaises(ValueError):
                    REPLAY.replay_study(study, POLICY)
        study = copy.deepcopy(original)
        study["cleanInputProof"]["revision"] = "coordinated"
        study["cleanInputProof"]["files"]["Package.swift"] = "changed"
        for recording in study["experiments"]:
            if recording["name"].startswith("clean-"):
                recording["metadata"]["candidateRevision"] = "coordinated"
        with self.assertRaises(ValueError):
            REPLAY.replay_study(study, POLICY)

    def test_coordinated_report_hash_and_verdict_edits_are_rejected(self):
        original = json.loads(SCRIPT.with_name("repeatability-study.json").read_text())
        for sample_index in (0, 2):
            with self.subTest(sample_index=sample_index):
                study = copy.deepcopy(original)
                recording = study["experiments"][0]
                samples = recording["runs"][0]["reference"]["scenarios"][0]["recordMilliseconds"]
                if sample_index == 0:
                    samples[0] = 9999
                else:
                    samples[2:] = [9999] * len(samples[2:])
                runs = REPLAY.expand_runs(recording)
                recording["reportSHA256"] = [
                    {side: hashlib.sha256(json.dumps(pair[side], sort_keys=True,
                        separators=(",", ":"), allow_nan=False).encode()).hexdigest()
                     for side in ("reference", "candidate")} for pair in runs]
                recording["result"] = GATE.evaluate(runs, POLICY)
                with self.assertRaises(ValueError):
                    REPLAY.replay_study(study, POLICY)

    def test_invalid_compressed_recording_is_rejected(self):
        recording = json.loads(SCRIPT.with_name("calibration.json").read_text())
        recording["runs"][0]["candidate"]["scenarios"][0]["retainedObservationCount"] = 46
        with self.assertRaises(ValueError):
            REPLAY.expand_runs(recording)
        recording["recordingFormat"] = "unknown"
        with self.assertRaises(ValueError):
            REPLAY.expand_runs(recording)

    def test_equal_workloads_pass_and_warmups_are_excluded(self):
        for pair in self.runs:
            pair["candidate"]["scenarios"][0]["recordMilliseconds"] = [10000, 10000, 6, 8, 10, 12, 14]
        result = GATE.evaluate(self.runs, POLICY)
        self.assertTrue(result["passed"])
        self.assertEqual(result["timings"][0]["candidateMedians"], [10, 10, 10])

    def test_record_and_series_regressions_fail_independently(self):
        for metric in ("recordMilliseconds", "seriesMilliseconds"):
            with self.subTest(metric=metric):
                runs = copy.deepcopy(self.runs)
                for pair in runs:
                    pair["candidate"]["scenarios"][2][metric] = [100] * 7
                result = GATE.evaluate(runs, POLICY)
                self.assertFalse(result["passed"])
                self.assertTrue(any(f"REGRESSION 25 accounts {metric}" in item for item in result["findings"]))

    def test_noisy_reference_is_inconclusive_and_fails(self):
        self.runs[0]["reference"]["scenarios"][0]["recordMilliseconds"] = [100] * 7
        result = GATE.evaluate(self.runs, POLICY)
        self.assertFalse(result["passed"])
        self.assertTrue(any("INCONCLUSIVE" in item for item in result["findings"]))

    def test_serialized_expansion_fails_without_steady_growth(self):
        for state in self.runs[0]["candidate"]["scenarios"][0]["retainedStates"]:
            state["serializedBytes"] *= 2
        result = GATE.evaluate(self.runs, POLICY)
        self.assertEqual(result["findings"], ["REGRESSION 1 accounts: serialized size"])

    def test_steady_growth_fails_without_serialized_expansion(self):
        states = self.runs[0]["candidate"]["scenarios"][0]["retainedStates"]
        # Remain below the unchanged reference maximum while the steady tail grows.
        for state in states[3:]:
            state["serializedBytes"] -= POLICY["maximumGrowthBytesPerAccount"] + 1
        states[-1]["serializedBytes"] += POLICY["maximumGrowthBytesPerAccount"] + 1
        result = GATE.evaluate(self.runs, POLICY)
        self.assertEqual(result["findings"], ["REGRESSION 1 accounts: retained serialized growth"])

    def test_malformed_measurements_never_pass(self):
        mutations = [
            lambda value: value.update(configuration="debug"),
            lambda value: value.update(timeZone="America/New_York"),
            lambda value: value["scenarios"].clear(),
            lambda value: value["scenarios"][0].update(seriesPointCount=0),
            lambda value: value["scenarios"][0].update(recordMilliseconds=[1] * 6),
            lambda value: value["scenarios"][0].update(recordMilliseconds=[float("nan")] * 7),
            lambda value: value["scenarios"][0].update(seriesMilliseconds=[float("inf")] * 7),
            lambda value: value["scenarios"][0]["retainedStates"].pop(),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(dailySnapshots=179),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(serializedBytes=float("nan")),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(serializedBytes=True),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                invalid = report()
                mutate(invalid)
                with self.assertRaises(ValueError):
                    GATE.validate(invalid)
        with self.assertRaises(ValueError):
            GATE.evaluate(self.runs[:2], POLICY)


if __name__ == "__main__":
    unittest.main()
