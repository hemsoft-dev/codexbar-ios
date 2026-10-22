#!/usr/bin/env python3
"""Compare the Release history workload with a frozen source revision."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
POLICY = Path(__file__).with_name("baseline.json")
ENV = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer", TZ="UTC")


def prepare_output(path):
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise ValueError("--output must be a new or empty directory; old results cannot prove this run")
    path.mkdir(parents=True, exist_ok=True)


def command(args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, env=ENV, text=True).strip()


def build(root, output, name):
    with (output / f"{name}-build.log").open("w") as log:
        subprocess.run(["xcrun", "swift", "build", "-c", "release", "--product", "UsageHistoryBenchmark"],
                       cwd=root, env=ENV, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = Path(command(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"], root)) / "UsageHistoryBenchmark"
    destination = output / name
    shutil.copy2(binary, destination)
    return destination


def reference_tree(revision, destination):
    # A full immutable git object is required. Never resolve a moving branch as a baseline.
    if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
        raise ValueError("baseline revision must be a full commit SHA")
    archive = subprocess.Popen(["git", "archive", revision], cwd=ROOT, stdout=subprocess.PIPE)
    try:
        subprocess.run(["tar", "-x", "-C", str(destination)], stdin=archive.stdout, check=True)
    finally:
        archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError("cannot archive baseline revision")
    shutil.copytree(ROOT / "PerformanceBenchmarks", destination / "PerformanceBenchmarks", dirs_exist_ok=True)
    manifest = destination / "Package.swift"
    content = manifest.read_text()
    if 'name: "UsageHistoryBenchmark"' not in content:
        product = '.executable(name: "UsageHistoryBenchmark", targets: ["UsageHistoryBenchmark"]),'
        target = '.executableTarget(name: "UsageHistoryBenchmark", dependencies: ["CodexBarIOS"], path: "PerformanceBenchmarks"),'
        for section, entry in (("products", product), ("targets", target)):
            marker = f"\n    {section}: [\n"
            if content.count(marker) != 1:
                raise ValueError(f"baseline manifest {section} section changed")
            content = content.replace(marker, marker + "        " + entry + "\n", 1)
        manifest.write_text(content)


def machine_snapshot(output, name):
    """Record diagnostic context without treating a missing probe as a timing result."""
    snapshot = dict(capturedAt=datetime.now(timezone.utc).isoformat(),
                    loadAverage=os.getloadavg(), logicalCPUs=os.cpu_count())
    for label, args in (("thermal", ["pmset", "-g", "therm"]),
                        ("memory", ["vm_stat"]),
                        ("processes", ["ps", "-axo", "pid,ppid,%cpu,%mem,etime,comm", "-r"])):
        try:
            result = subprocess.run(args, env=ENV, text=True, capture_output=True, timeout=5, check=False)
            # Executable names expose competing work without capturing command arguments or secrets.
            stdout = "\n".join(result.stdout.splitlines()[:21]) if label == "processes" else result.stdout
            snapshot[label] = dict(exitCode=result.returncode, stdout=stdout, stderr=result.stderr)
        except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError) as error:
            snapshot[label] = dict(error=str(error))
    (output / f"{name}-machine.json").write_text(json.dumps(snapshot, indent=2) + "\n")


def admission_snapshot(*, timeout=5):
    result = subprocess.run(["ps", "-axo", "%cpu=,comm="], env=dict(ENV, LC_ALL="C"),
                            text=True, capture_output=True, timeout=timeout, check=True)
    rows = result.stdout.splitlines()
    if not rows:
        raise ValueError("missing process CPU observations")
    busy = []
    for row in rows:
        cpu, executable = row.strip().split(maxsplit=1)
        utilization = float(cpu)
        if not math.isfinite(utilization) or utilization < 0:
            raise ValueError("invalid process CPU observation")
        name = Path(executable).name
        if utilization >= 10 and (name.startswith(("swift", "clang", "xcodebuild", "simctl", "Simulator", "CoreSimulator"))
                                  or "/Simulator.app/" in executable or "CoreSimulator" in executable
                                  or ".simruntime/" in executable
                                  or name in ("launchd_sim", "testmanagerd")):
            busy.append(dict(executable=executable, cpu=utilization))
    return dict(capturedAt=datetime.now(timezone.utc).isoformat(), logicalCPUs=os.cpu_count(),
                loadAverage=list(os.getloadavg()), busyProcesses=busy)


def admit_quiet_host(output, *, snapshot=admission_snapshot, sleep=time.sleep, monotonic=time.monotonic):
    """Admit one fixed experiment, never choose or discard its timing results."""
    started = monotonic()
    receipt = dict(passed=False, maximumSeconds=420, requiredConsecutiveSamples=9,
                   sampleIntervalSeconds=15, maximumNormalizedLoad=1.0, samples=[])
    consecutive = 0
    quiet_since, failure = None, None
    try:
        while True:
            remaining = 420 - (monotonic() - started)
            if remaining <= 0:
                raise ValueError("quiet host admission failed within the fixed 420-second budget")
            observation = snapshot(timeout=min(5, remaining))
            elapsed = monotonic() - started
            try:
                saved_observation = json.loads(json.dumps(observation, allow_nan=False))
            except (TypeError, ValueError):
                saved_observation = {"unserializableObservation": repr(observation)}
            sample = dict(observation=saved_observation, elapsedSeconds=elapsed,
                          valid=False, quiet=False, consecutiveQuietSamples=0)
            receipt["samples"].append(sample)
            if not isinstance(observation, dict):
                raise ValueError("invalid quiet host observation")
            cpus, loads, busy = (observation.get(key) for key in ("logicalCPUs", "loadAverage", "busyProcesses"))
            if (type(cpus) is not int or cpus <= 0 or not isinstance(loads, (list, tuple)) or len(loads) != 3
                    or any(type(value) not in (int, float) or not math.isfinite(value) or value < 0 for value in loads)
                    or not isinstance(busy, list)):
                raise ValueError("invalid quiet host observation")
            quiet = loads[0] / cpus <= 1.0 and not busy
            consecutive = consecutive + 1 if quiet else 0
            elapsed = monotonic() - started
            quiet_since = (elapsed if quiet_since is None else quiet_since) if quiet else None
            sample.update(valid=True, quiet=quiet, consecutiveQuietSamples=consecutive)
            if consecutive >= 9 and elapsed - quiet_since >= 120 and elapsed <= 420:
                receipt["passed"] = True
                return
            if elapsed >= 420:
                raise ValueError("quiet host admission failed within the fixed 420-second budget")
            sleep(min(15, 420 - elapsed))
    except BaseException as error:
        failure = error
        receipt["error"] = str(error)
        raise
    finally:
        receipt["elapsedSeconds"] = monotonic() - started
        try:
            (output / "host-admission.json").write_text(json.dumps(receipt, indent=2, allow_nan=False) + "\n")
        except OSError:
            if failure is None:
                raise
            print("Unable to preserve host admission receipt; retaining the primary failure.", file=sys.stderr)


def measure(binary, output, name):
    machine_snapshot(output, f"{name}-before")
    try:
        # Keep stdout/stderr even when the process, JSON parser, or fixture assertion fails.
        with (output / f"{name}.json").open("w") as stdout, (output / f"{name}.stderr.log").open("w") as stderr:
            subprocess.run([str(binary)], cwd=ROOT, env=ENV, text=True,
                           stdout=stdout, stderr=stderr, check=True)
    finally:
        machine_snapshot(output, f"{name}-after")
    report = json.loads((output / f"{name}.json").read_text())
    validate(report)
    return report


def validate(report):
    if (report["configuration"] != "release" or report["fixtureVersion"] != 1 or report["timeZone"] != "UTC"
            or report["warmupBatches"] != 2 or report["measuredBatches"] != 5
            or report["seriesIterationsPerBatch"] != 5
            or [row["accounts"] for row in report["scenarios"]] != [1, 10, 25]):
        raise ValueError("benchmark configuration or fixture mismatch")
    for row in report["scenarios"]:
        accounts = row["accounts"]
        if row["seriesPointCount"] != accounts * 329 * 5 * 7:
            raise ValueError("series workload changed")
        for metric in ("recordMilliseconds", "seriesMilliseconds"):
            samples = row[metric]
            if len(samples) != 7 or any(type(x) not in (float, int) or not math.isfinite(x) or x <= 0 for x in samples):
                raise ValueError("missing or invalid timing samples")
        states = row["retainedStates"]
        if len(states) != 47 or any(state["snapshots"] != 240 * accounts
                                   or state["dailySnapshots"] != 180 * accounts
                                   or type(state["serializedBytes"]) is not int
                                   or state["serializedBytes"] <= 0 for state in states):
            raise ValueError("retained-state workload changed")


def evaluate(runs, policy):
    if len(runs) < 3:
        raise ValueError("at least three paired runs are required")
    findings, summary = [], []
    for pair in runs:
        for side in ("reference", "candidate"):
            validate(pair[side])
    for index, accounts in enumerate((1, 10, 25)):
        for metric in ("recordMilliseconds", "seriesMilliseconds"):
            medians = {side: [statistics.median(pair[side]["scenarios"][index][metric][2:]) for pair in runs]
                       for side in ("reference", "candidate")}
            ratios = [new / old for old, new in zip(medians["reference"], medians["candidate"])]
            ratio = statistics.median(ratios)
            # A noisy control cannot establish a pass, even if its slowness helps the candidate.
            noise = max(statistics.pstdev(values) / statistics.mean(values) for values in medians.values())
            summary.append(dict(accounts=accounts, metric=metric, referenceMedians=medians["reference"],
                                candidateMedians=medians["candidate"], ratios=ratios, medianRatio=ratio, noiseCV=noise,
                                withinRunCV={side: [statistics.pstdev(pair[side]["scenarios"][index][metric][2:]) /
                                                  statistics.mean(pair[side]["scenarios"][index][metric][2:]) for pair in runs]
                                             for side in ("reference", "candidate")}))
            if noise > policy["maximumRunCV"]:
                findings.append(f"INCONCLUSIVE {accounts} accounts {metric}: run CV {noise:.3f}")
            if ratio > policy["maximumLatencyRatio"]:
                findings.append(f"REGRESSION {accounts} accounts {metric}: ratio {ratio:.3f}")
        for pair in runs:
            old = [state["serializedBytes"] for state in pair["reference"]["scenarios"][index]["retainedStates"]]
            new = [state["serializedBytes"] for state in pair["candidate"]["scenarios"][index]["retainedStates"]]
            if max(new) > max(old) * policy["maximumSerializedRatio"]:
                findings.append(f"REGRESSION {accounts} accounts: serialized size")
            # Ignore the initial seed and two warmups; persist every later retained-state sample.
            steady = new[3:]
            if max(steady) - steady[0] > policy["maximumGrowthBytesPerAccount"] * accounts:
                findings.append(f"REGRESSION {accounts} accounts: retained serialized growth")
    return dict(passed=not findings, findings=sorted(set(findings)), timings=summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--prove-slowdown", action="store_true",
                        help="insert 120ms into record in a disposable reference copy; expect the ordinary gate to fail")
    args = parser.parse_args()
    if args.pairs < 3:
        parser.error("--pairs must be at least three")
    args.output = args.output.resolve()
    prepare_output(args.output)
    policy = json.loads(POLICY.read_text())
    metadata = dict(startedAt=datetime.now(timezone.utc).isoformat(), baselineRevision=policy["revision"],
                    candidateRevision=command(["git", "rev-parse", "HEAD"]),
                    candidateDirty=bool(command(["git", "status", "--porcelain"])),
                    hardware=command(["sysctl", "-n", "hw.model"]), cpu=command(["sysctl", "-n", "machdep.cpu.brand_string"]),
                    memoryBytes=command(["sysctl", "-n", "hw.memsize"]), architecture=command(["uname", "-m"]),
                    operatingSystem=command(["sw_vers"]), swift=command(["xcrun", "swift", "--version"]),
                    xcode=command(["xcodebuild", "-version"]), configuration="release", timezone="UTC",
                    benchmarkSHA256=hashlib.sha256((ROOT / "PerformanceBenchmarks/UsageHistoryBenchmark.swift").read_bytes()).hexdigest(),
                    slowdownProof=args.prove_slowdown, policy=policy)
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="usage-history-reference-") as temporary:
        reference = Path(temporary)
        reference_tree(policy["revision"], reference)
        binaries = {"reference": build(reference, args.output, "reference")}
        if args.prove_slowdown:
            source = reference / "CodexBarIOS/Services/UsageHistoryStore.swift"
            text = source.read_text()
            marker = "        let recordableResults = results.filter { result in"
            if text.count(marker) != 1:
                raise ValueError("slowdown injection target changed")
            source.write_text(text.replace(marker, "        Thread.sleep(forTimeInterval: 0.12)\n" + marker))
            binaries["candidate"] = build(reference, args.output, "candidate-slowdown")
        else:
            binaries["candidate"] = build(ROOT, args.output, "candidate")
        admit_quiet_host(args.output)
        runs = []
        for index in range(args.pairs):
            pair = {}
            order = ("reference", "candidate") if index % 2 == 0 else ("candidate", "reference")
            for side in order:
                print(f"Pair {index + 1}/{args.pairs}: {side}", flush=True)
                pair[side] = measure(binaries[side], args.output, f"{index + 1}-{side}")
            runs.append(pair)
        result = evaluate(runs, policy)
        result["metadata"] = metadata
        (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        for item in result["timings"]:
            print(f'{item["accounts"]:2} accounts {item["metric"]}: {item["medianRatio"]:.3f}x; CV {item["noiseCV"]:.3f}')
        for finding in result["findings"]:
            print(finding)
        raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
