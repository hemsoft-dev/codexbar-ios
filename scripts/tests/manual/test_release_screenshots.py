#!/usr/bin/env python3
"""Explicit local-only screenshot contract checks; not automatic test discovery."""
import os
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock
import io
import contextlib
import struct
import zlib

ROOT = Path(__file__).resolve().parents[3]
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def source_boundary(text, marker):
    if text.count(marker) != 1:
        raise AssertionError(f"Expected exactly one source boundary: {marker!r}")
    before, _, after = text.partition(marker)
    return before, after


class ReleaseScreenshotContractTests(unittest.TestCase):
    def test_all_capture_scenes_parse_and_feature_the_intended_account(self):
        fixture = (ROOT / "CodexBarIOS/Services/AppStoreScreenshotFixtures.swift").read_text()
        # Compile the real configuration/parser and featured-account helper.
        # The store spy observes routing only; native captures prove rendering.
        source = source_boundary(fixture, "    static func results")[0] + "}\n#endif\n"
        scenes = re.findall(r'^  "([^:]+):(?:light|dark)"$',
                            (ROOT / "scripts/capture-app-store-screenshots.sh").read_text(), re.M)
        self.assertEqual(len(scenes), 9)
        self.assertEqual(len(set(scenes)), 9)
        catalog = (ROOT / "CodexBarIOS/Models/GoogleUsageMetricCatalog.swift").read_text()
        source += source_boundary(catalog, "    public static func metrics")[0] + "}\n"
        source += r'''
public enum ProviderID: String, Sendable { case other }
enum MetricTileWidthPreference { case half }
@MainActor final class ProviderConfigurationStore {
    var orders: [[String]] = []
    var halfWidthMetrics: [String] = []
    func updateDashboardCardOrder(_ ids: [String]) { orders.append(ids) }
    func updateMetricWidth(_ width: MetricTileWidthPreference, accountID: String, metricID: String) {
        halfWidthMetrics.append(metricID)
    }
}
@main struct Contract {
    @MainActor static func main() {
        let scenes = SCENES
        let featured = ["grok": AppStoreScreenshotFixtureID.grokAccount,
                        "github-billing": AppStoreScreenshotFixtureID.githubBillingAccount]
        for raw in scenes {
            let config = AppStoreScreenshotConfiguration.parse(arguments: [
                "--app-store-screenshots", "--app-store-scene", raw,
                "--app-store-appearance", "dark", "--app-store-settle-seconds", "50"
            ])!
            precondition(config.scene.rawValue == raw)
            precondition(config.appearance == .dark && config.settleDelay == 30)
            let store = ProviderConfigurationStore()
            AppStoreScreenshotFixtures.featureAccount(for: config.scene, in: store)
            precondition(store.orders == (featured[raw].map { [[$0]] } ?? []))
            precondition(store.halfWidthMetrics.isEmpty)
        }
        precondition(AppStoreScreenshotConfiguration.parse(arguments: ["--app-store-scene", "retired-provider"]) == nil)
        let fallback = AppStoreScreenshotConfiguration.parse(arguments: [
            "--app-store-screenshots", "--app-store-scene", "invalid",
            "--app-store-settle-seconds", "-2"
        ])!
        precondition(fallback.scene == .dashboardOverview && fallback.settleDelay == 0)
        print("Eight real parser/routing contracts passed; normal launch stays inactive.")
    }
}
'''.replace("SCENES", str(scenes).replace("'", '"'))
        env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
        with tempfile.TemporaryDirectory(prefix="codexbar-screenshot-contract-") as directory:
            path = Path(directory)
            (path / "Contract.swift").write_text(source)
            subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-parse-as-library",
                            str(ROOT / "CodexBarIOS/Models/AppAppearance.swift"),
                            str(path / "Contract.swift"), "-o", str(path / "contract")],
                           env=env, check=True)
            subprocess.run([str(path / "contract")], env=env, check=True)

    def test_fixed_monthly_fixture_captions_preserve_metric_fields(self):
        fixture = (ROOT / "CodexBarIOS/Services/AppStoreScreenshotFixtures.swift").read_text()
        helper = source_boundary(source_boundary(fixture, "    private static func captureBars")[1],
                                 "    static func historyStore")[0]
        usage = (ROOT / "CodexBarIOS/Models/UsageBar.swift").read_text()
        # Compile the actual stored fields, initializer, and capture helper.
        bar = "public struct UsageBar" + source_boundary(source_boundary(usage, "public struct UsageBar")[1],
                                                       "    public var fractionUsed")[0] + "}\n"
        fields = re.findall(r"public let (\w+):", bar)
        preserved = [x for x in fields if x not in ("resetDescription", "resetsAt", "resetDisplayStyle")]
        checks = "\n".join(f"precondition(output.{x} == input.{x})" for x in preserved)
        source = "import Foundation\npublic enum UsageResetDisplayStyle: Equatable, Sendable { case verbatim, relative }\n"
        source += "public enum UsageProjectionSignificance: Equatable, Sendable { case warning }\n" + bar
        source += "enum ProviderID { case cursor, githubBilling, other }\n"
        source += "enum Fixture { static func captureBars" + helper + "}\n"
        source += r'''
@main struct Contract {
    static func main() {
        let stamp = Date(timeIntervalSince1970: 100)
        let cases: [(ProviderID, String, String, Bool)] = [
            (.cursor, "Models", "Resets Nov 1", true),
            (.githubBilling, "Actions minutes", "Resets Jan 1", true),
            (.other, "MONTHLY limit", "Resets Dec 1", true),
            (.other, "Five-hour", "Resets Aug 1", false),
            (.other, "Weekly", "Resets Monday", false)
        ]
        for (provider, label, caption, monthly) in cases {
            let input = UsageBar(stableKey: "fixed", label: label, used: 24, limit: 100,
                resetDescription: caption, resetsAt: stamp, resetDisplayStyle: .relative,
                fractionlessUsageText: "usage", projectionCurrent: 12, projectionLimit: 30,
                projectionPeriodStart: stamp, projectionPeriodEnd: stamp,
                showProjectionOnCurrentBar: true, projectionDescriptionOverride: "projection",
                projectionSignificanceOverride: .warning)
            let output = Fixture.captureBars([input], providerID: provider)[0]
            CHECKS
            if monthly {
                precondition(output.resetDescription == "Resets next month")
                precondition(output.resetsAt == nil && output.resetDisplayStyle == .verbatim)
            } else { precondition(output == input) }
        }
        precondition(Fixture.captureBars([], providerID: .other).isEmpty)
    }
}
'''.replace("CHECKS", checks)
        env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
        with tempfile.TemporaryDirectory(prefix="codexbar-monthly-fixture-") as directory:
            path = Path(directory)
            (path / "Contract.swift").write_text(source)
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Contract.swift"),
                            "-o", str(path / "contract")], env=env, check=True)
            subprocess.run([str(path / "contract")], env=env, check=True)

    def test_watch_flattening_removes_alpha_without_resizing(self):
        script = (ROOT / "scripts/flatten-storefront-image.sh").read_text()
        swift = script.split("<<'SWIFT'\n", 1)[1].split("\nSWIFT", 1)[0]

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        # Transparent and opaque pixels, encoded losslessly without third-party tools.
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(
            b"\0\xff\0\0\0\0\xff\0\xff\0\0\0\xff\x80\xff\xff\xff\xff"))
        png += chunk(b"IEND", b"")
        env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
        with tempfile.TemporaryDirectory(prefix="codexbar-watch-png-") as directory:
            input_path, output_path = Path(directory) / "alpha.png", Path(directory) / "opaque.png"
            input_path.write_bytes(png)
            subprocess.run(["xcrun", "swift", "-", str(input_path), str(output_path)],
                           input=swift, text=True, env=env, check=True)
            output = output_path.read_bytes()
            self.assertEqual(struct.unpack(">II", output[16:24]), (2, 2))
            self.assertEqual(output[25], 2, "PNG must be RGB, not RGBA")

    def test_simulator_selection_binds_name_runtime_and_sdk(self):
        spec = importlib.util.spec_from_file_location("ios_selector", ROOT / "scripts/select-ios-screenshot-simulator.py")
        selector = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(selector)
        old, new = "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        data = {"runtimes": [
            {"identifier": old, "version": "26.5", "isAvailable": True},
            {"identifier": new, "version": "27.0", "isAvailable": True}
        ], "devices": {
            old: [{"name": "Same Phone", "udid": "old-id", "isAvailable": True}],
            new: [{"name": "Same Phone", "udid": "new-id", "isAvailable": True}]
        }}
        self.assertEqual(selector.select_device(data, "Same Phone", "26.5", "27.0"), "old-id")
        self.assertEqual(selector.select_device(data, "Same Phone", "latest", "26.5"), "old-id")
        self.assertEqual(selector.select_device(data, "Same Phone", "latest", "27.0"), "new-id")
        with self.assertRaisesRegex(ValueError, "compatible"):
            selector.select_device(data, "Same Phone", "27.0", "26.5")
        with self.assertRaisesRegex(ValueError, "No available"):
            selector.select_device(data, "Missing", "26.5", "27.0")
        data["devices"][new][0]["isAvailable"] = False
        with self.assertRaisesRegex(ValueError, "No available"):
            selector.select_device(data, "Same Phone", "latest", "27.0")

    def test_selector_command_failures_exit_without_a_traceback(self):
        spec = importlib.util.spec_from_file_location("selector_errors", ROOT / "scripts/select-ios-screenshot-simulator.py")
        selector = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(selector)
        for error in (subprocess.CalledProcessError(72, ["xcrun", "simctl"]), OSError("tool missing")):
            output = io.StringIO()
            with mock.patch("sys.argv", ["selector", "--name", "Fixture"]), \
                    mock.patch.object(selector.subprocess, "check_output", side_effect=error), \
                    contextlib.redirect_stderr(output), self.assertRaises(SystemExit) as result:
                selector.main()
            self.assertEqual(result.exception.code, 1)
            self.assertIn("Simulator discovery", output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())

    def test_source_boundaries_fail_with_a_specific_error(self):
        self.assertEqual(source_boundary("left-boundary-right", "-boundary-"), ("left", "right"))
        for source in ("missing", "duplicate duplicate"):
            with self.assertRaisesRegex(AssertionError, "source boundary"):
                source_boundary(source, "duplicate")

    def test_capture_outputs_and_toolchain_selection_remain_explicit(self):
        ios = (ROOT / "scripts/capture-app-store-screenshots.sh").read_text()
        watch = (ROOT / "scripts/capture-watch-app-store-screenshots.sh").read_text()
        self.assertIn('--os "$IOS_SIMULATOR_OS"', ios)
        self.assertIn('platform=iOS Simulator,id=$phone_id', ios)
        self.assertIn('local raw_path="$RAW_CAPTURE_DIR/', ios)
        self.assertNotIn('local raw_path="$OUTPUT_DIR/.raw', ios)
        self.assertIn('IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-latest}"', ios)
        for text in (ios, watch):
            self.assertIn('OUTPUT_DIR="${OUTPUT_DIR:-', text)
            self.assertIn('DERIVED_DATA="${DERIVED_DATA:-', text)
            self.assertIn('-skipPackagePluginValidation', text)
            self.assertIn('scripts/flatten-storefront-image.sh', text)
        self.assertIn('release-assets/1.4.0/screenshots', watch)
        self.assertNotIn('release-assets/1.2/screenshots', watch)
        self.assertFalse((Path(__file__).parent / "__init__.py").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
