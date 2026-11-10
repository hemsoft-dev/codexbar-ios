#!/usr/bin/env python3
"""Manual-only baseline/candidate native UI comparison. Never a release gate."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


JOURNEY = "CodexBarIOSUITests/SettingsEvidenceUITests/testRetiredGoogleUpgradeEvidence"


def passed_one(summary):
    return all(summary.get(key) == value for key, value in {
        "result": "Passed", "totalTestCount": 1, "passedTests": 1,
        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
    }.items())


def classify_baseline(exit_code, summary):
    if exit_code == 0 and passed_one(summary):
        return "passed"
    failures = summary.get("testFailures", [])
    known_failure = bool(failures) and all(
        "Control is unreachable at accessibility text size" in failure.get("failureText", "").split("\n")[0]
        and "Configure account Fixture" in failure.get("failureText", "").split("\n")[0]
        and "testRetiredGoogleUpgradeEvidence" in failure.get("testIdentifierString", "")
        for failure in failures
    )
    if exit_code == 65 and known_failure and all(summary.get(key) == value for key, value in {
        "result": "Failed", "totalTestCount": 1, "passedTests": 0,
        "failedTests": 1, "skippedTests": 0, "expectedFailures": 0,
    }.items()):
        return "known-menu-failure"
    return "unclassified-failure"


def choose_device(simulators, sdk_version, family):
    def version(value):
        return tuple((list(map(int, value.split("."))) + [0, 0, 0])[:3])
    choices = []
    for runtime in simulators["runtimes"]:
        if not runtime.get("isAvailable") or not runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if version(runtime["version"]) > version(sdk_version):
            continue
        for device in simulators["devices"].get(runtime["identifier"], []):
            if device.get("isAvailable") and device["name"].startswith(family):
                choices.append((version(runtime["version"]), device["name"], device["udid"], runtime, device))
    if not choices:
        raise RuntimeError(f"No compatible {family} device for SDK {sdk_version}")
    _, _, _, runtime, device = max(choices, key=lambda item: item[:3])
    return runtime, device


def main():
    repo = Path(__file__).resolve().parents[1]
    baseline = os.environ.get("ACCOUNT_MENU_BASE_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", baseline):
        raise RuntimeError("ACCOUNT_MENU_BASE_SHA must be an exact 40-character commit SHA")
    environment = {key: value for key, value in os.environ.items() if not re.search(
        r"TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIAL|COOKIE|AUTHORIZATION", key, re.I
    )}
    environment["DEVELOPER_DIR"] = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

    def output(*command):
        return subprocess.check_output(command, cwd=repo, env=environment, text=True).strip()

    candidate = output("git", "rev-parse", "HEAD")
    if os.environ.get("GITHUB_SHA", candidate) != candidate:
        raise RuntimeError("Checked-out candidate differs from the dispatched SHA")
    subprocess.run(["git", "merge-base", "--is-ancestor", baseline, candidate], cwd=repo, env=environment, check=True)
    expected_xcode = json.loads((repo / "scripts/function-risk/policy.json").read_text())["tools"]["xcode"]
    xcode = output("xcodebuild", "-version")
    if xcode != expected_xcode:
        raise RuntimeError(f"Canonical toolchain required: {expected_xcode!r}; found {xcode!r}")
    sdk = output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
    simulators = json.loads(output("xcrun", "simctl", "list", "--json"))
    results = Path(os.environ.get("UI_TEST_RESULTS_DIR", str(repo / "build/ui-tests"))).resolve()
    results.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="account-menu.", dir=results))
    report = {"baselineSHA": baseline, "candidateSHA": candidate, "xcode": xcode, "sdk": sdk, "journey": JOURNEY, "runs": []}
    owned = []

    def logged(command, folder, cwd):
        with (folder / "xcodebuild.log").open("w") as log:
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                if "PrebuildCommand(" in line:
                    line = "[Suppressed environment-bearing SwiftPM diagnostic.]\n"
                log.write(line)
            return process.wait()

    try:
        with tempfile.TemporaryDirectory(prefix="account-menu-source.") as temporary:
            sources = {}
            for label, revision in [("baseline", baseline), ("candidate", candidate)]:
                source = Path(temporary) / label
                source.mkdir()
                with tempfile.TemporaryFile() as archive:
                    subprocess.run(["git", "archive", revision], cwd=repo, env=environment, stdout=archive, check=True)
                    archive.seek(0)
                    subprocess.run(["tar", "-xf", "-", "-C", str(source)], stdin=archive, env=environment, check=True)
                sources[label] = source
            for label in ["baseline", "candidate"]:
                for family, prefix in [("iphone", "iPhone"), ("ipad", "iPad")]:
                    folder = run / f"{label}-{family}"
                    folder.mkdir()
                    runtime, template = choose_device(simulators, sdk, prefix)
                    device = output("xcrun", "simctl", "create", f"AccountMenu-{label}-{family}", template["deviceTypeIdentifier"], runtime["identifier"])
                    owned.append(device)
                    output("xcrun", "simctl", "boot", device)
                    output("xcrun", "simctl", "bootstatus", device, "-b")
                    row = {"revision": label, "family": family, "device": device, "deviceName": template["name"], "runtime": runtime["version"]}
                    report["runs"].append(row)
                    recording = None
                    video_log = (folder / "recording.log").open("w")
                    try:
                        if label == "candidate" and family == "ipad":
                            row["recordingStartedAt"] = time.time()
                            recording = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", str(folder / "interaction.mp4")], env=environment, stdout=video_log, stderr=subprocess.STDOUT)
                        row["exitCode"] = logged([
                            "xcodebuild", "-quiet", "-project", "CodexBarIOS.xcodeproj", "-scheme", "CodexBarIOSUITests",
                            "-configuration", "Debug", "-skipPackagePluginValidation", "-destination", f"platform=iOS Simulator,id={device}",
                            "-derivedDataPath", str(Path(temporary) / f"DerivedData-{label}"), "-resultBundlePath", str(folder / "journey.xcresult"),
                            "-parallel-testing-enabled", "NO", f"-only-testing:{JOURNEY}", "CODE_SIGNING_ALLOWED=NO", "test",
                        ], folder, sources[label])
                    finally:
                        if recording:
                            recording.send_signal(signal.SIGINT)
                            recording.wait(timeout=30)
                        video_log.close()
                    bundle = folder / "journey.xcresult"
                    try:
                        summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)))
                        (folder / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                        row["classification"] = classify_baseline(row["exitCode"], summary) if label == "baseline" else (
                            "passed" if row["exitCode"] == 0 and passed_one(summary) else "candidate-failure"
                        )
                    except (subprocess.CalledProcessError, ValueError):
                        row["classification"] = "missing-summary"
                    if bundle.exists():
                        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(folder / "attachments")], env=environment, check=True, stdout=subprocess.DEVNULL)
                    print(label, family, row["classification"], flush=True)
                    # Each source/family uses a fresh owned simulator, with no retry.
                    output("xcrun", "simctl", "shutdown", device)
    finally:
        (run / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
        for device in owned:
            subprocess.run(["xcrun", "simctl", "delete", device], env=environment, check=False)
    if len(report["runs"]) != 4 or any(row.get("classification") not in (
        ["passed", "known-menu-failure"] if row["revision"] == "baseline" else ["passed"]
    ) for row in report["runs"]):
        raise RuntimeError(f"Comparison incomplete or failed; inspect {run}")
    print(f"Canonical comparison passed; baseline outcomes retained. Not a full release gate. Results: {run}")


if __name__ == "__main__":
    main()
