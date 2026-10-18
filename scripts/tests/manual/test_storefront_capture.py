"""Offline capture-driver regressions; manual only, with every subprocess mocked.

Set STOREFRONT_CAPTURE_SCRIPT to test a driver outside this test's repository.
"""

import argparse
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
SCRIPT = Path(os.environ.get("STOREFRONT_CAPTURE_SCRIPT", ROOT / "scripts/capture-storefront-assets.py"))
SPEC = importlib.util.spec_from_file_location("storefront_capture_under_test", SCRIPT)
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)
REAL_RUN_WRAPPER = CAPTURE.run
SOURCE = "a" * 40
IOS_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
WATCH_RUNTIME = "com.apple.CoreSimulator.SimRuntime.watchOS-27-0"


def inventories(build="6"):
    return {
        "iphone": {
            "path": "/synthetic/CodexBarIOS.app", "sha256": "b" * 64, "files": {},
            "bundles": [
                {"bundle": ".", "version": "2.0.0", "build": build},
                {"bundle": "PlugIns/Widget.appex", "version": "2.0.0", "build": build},
                {"bundle": "Watch/Companion.app", "version": "2.0.0", "build": build},
                {"bundle": "Watch/Companion.app/PlugIns/Complication.appex", "version": "2.0.0", "build": build},
            ],
        },
        "watch": {
            "path": "/synthetic/CodexBarWatch.app", "sha256": "c" * 64, "files": {},
            "bundles": [
                {"bundle": ".", "version": "2.0.0", "build": build},
                {"bundle": "PlugIns/Complication.appex", "version": "2.0.0", "build": build},
            ],
        },
    }


def device_inputs():
    return {family: {"simulator_udid": family + "-owned-id", "owner": "issue-469",
                     "name": "Stale " + family, "runtime": "iOS 1.0",
                     "runtime_system_version": {"ProductVersion": "1.0"}}
            for family in ("iphone", "ipad", "watch")}


def simulator_inventory():
    return {"devices": {
        IOS_RUNTIME: [{"udid": family + "-owned-id", "name": "CodexBar-469-Actual-" + family,
                       "isAvailable": True} for family in ("iphone", "ipad")],
        WATCH_RUNTIME: [{"udid": "watch-owned-id", "name": "CodexBar-469-Actual-watch", "isAvailable": True}],
    }}


def tree_bytes(root):
    return {str(p.relative_to(root)): ("directory" if p.is_dir() else p.read_bytes())
            for p in sorted(root.rglob("*"))}


class StorefrontCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="storefront-capture-contract-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        (self.repo / "fixture.swift").write_text("// committed synthetic source\n")
        self.devices = self.folder / "devices.json"
        self.devices.write_text(json.dumps(device_inputs()))
        self.run_guard = self.enterContext(mock.patch.object(
            CAPTURE, "run", side_effect=AssertionError("Unmocked external command")))
        self.subprocess_guard = self.enterContext(mock.patch.object(
            CAPTURE.subprocess, "run", side_effect=AssertionError("Real subprocess forbidden")))
        self.enterContext(mock.patch.object(CAPTURE, "committed_source", return_value=SOURCE))
        self.enterContext(mock.patch.object(CAPTURE, "clean_environment", return_value={"PATH": "/synthetic"}))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def fake_build(self, apps=None, work=None):
        apps = copy.deepcopy(apps if apps is not None else inventories())
        args = argparse.Namespace(root=self.repo, devices=self.devices,
                                  work_dir=work or self.folder / "fresh-build")
        native_commands = []

        def run(*arguments, **kwargs):
            arguments = tuple(str(x) for x in arguments)
            if arguments == ("git", "ls-files"):
                return "fixture.swift"
            if arguments == ("xcodebuild", "-version"):
                return "Synthetic Xcode\nBuild version TEST"
            if arguments[0] == "xcodebuild" and kwargs.get("log"):
                native_commands.append(arguments)
                Path(kwargs["log"]).write_bytes(b"synthetic successful build\n")
                derived = Path(arguments[arguments.index("-derivedDataPath") + 1])
                derived.mkdir()
                (derived / "product.marker").write_bytes(b"synthetic product\x00\xff")
                return types.SimpleNamespace(returncode=0)
            raise AssertionError(f"Unexpected command: {arguments}")

        def inventory(path):
            family = "watch" if Path(path).name == "CodexBarWatch.app" else "iphone"
            result = copy.deepcopy(apps[family])
            result["path"] = str(path)
            return result

        self.run_guard.side_effect = run
        reader = self.enterContext(mock.patch.object(CAPTURE, "read_devices", return_value=device_inputs()))
        self.enterContext(mock.patch.object(CAPTURE, "bundle_inventory", side_effect=inventory))
        return args, native_commands, reader

    def capture_case(self, receipt_build="6", receipt_version="2.0.0", actual=None):
        apps = inventories()
        case_folder = Path(tempfile.mkdtemp(prefix="capture-case-", dir=self.folder))
        receipt = {"source_commit": SOURCE, "version": receipt_version, "build": receipt_build,
                   "xcode": "Synthetic Xcode", "apps": apps}
        build_receipt = case_folder / "build-provenance.json"
        build_receipt.write_text(json.dumps(receipt))
        manifest = case_folder / "captions.json"
        manifest.write_text(json.dumps({"assets": []}))
        args = argparse.Namespace(root=self.repo, devices=self.devices, build_receipt=build_receipt,
                                  manifest=manifest, receipt=case_folder / "capture-provenance.json",
                                  output_root=case_folder / "images", settle_seconds=0)
        actual = copy.deepcopy(actual if actual is not None else apps)
        inventory = self.enterContext(mock.patch.object(
            CAPTURE, "bundle_inventory", side_effect=lambda path: copy.deepcopy(
                actual["watch" if Path(path).name == "CodexBarWatch.app" else "iphone"])))
        reader = self.enterContext(mock.patch.object(CAPTURE, "read_devices", return_value=device_inputs()))
        return args, inventory, reader

    def test_verified_build_six_includes_every_app_and_nested_extension(self):
        self.assertEqual(CAPTURE.verified_bundle_version(inventories()), {"version": "2.0.0", "build": "6"})

    def test_mixed_build_or_version_in_any_nested_bundle_is_rejected(self):
        for family, app in inventories().items():
            for position in range(len(app["bundles"])):
                for field, value in (("build", "5"), ("version", "2.1.0")):
                    with self.subTest(family=family, bundle=position, field=field):
                        apps = inventories()
                        apps[family]["bundles"][position][field] = value
                        with self.assertRaises(ValueError):
                            CAPTURE.verified_bundle_version(apps)

    def test_empty_app_or_bundle_inventory_is_rejected(self):
        for apps in ({}, {"iphone": {"bundles": []}}, {"iphone": {}}):
            with self.subTest(apps=apps), self.assertRaises(ValueError):
                CAPTURE.verified_bundle_version(apps)

    def test_new_build_directory_records_actual_build_six(self):
        args, native, _ = self.fake_build()
        CAPTURE.build(args)
        receipt = json.loads((args.work_dir / "build-provenance.json").read_text())
        self.assertEqual(receipt["build"], "6")
        self.assertEqual(receipt["version"], "2.0.0")
        self.assertEqual(len(native), 2)
        self.assertEqual(receipt["source_files"]["fixture.swift"], CAPTURE.sha256(self.repo / "fixture.swift"))
        self.subprocess_guard.assert_not_called()

    def test_first_run_directory_can_create_logs_products_and_receipt(self):
        args, native, _ = self.fake_build(inventories("5"))
        CAPTURE.build(args)
        self.assertEqual(len(native), 2)
        for family in ("iphone", "watch"):
            self.assertEqual((args.work_dir / f"{family}-final-build.log").read_bytes(), b"synthetic successful build\n")
            self.assertEqual((args.work_dir / f"{family}-final-build/product.marker").read_bytes(), b"synthetic product\x00\xff")
        self.assertTrue((args.work_dir / "build-provenance.json").is_file())
        self.subprocess_guard.assert_not_called()

    def test_build_refuses_mixed_bundle_versions_without_publishing_receipt(self):
        apps = inventories()
        apps["iphone"]["bundles"][-1]["build"] = "5"
        args, _, _ = self.fake_build(apps)
        with self.assertRaises(ValueError):
            CAPTURE.build(args)
        self.assertFalse((args.work_dir / "build-provenance.json").exists())

    def assert_existing_work_is_preserved(self, populated):
        work = self.folder / "preserved-build"
        work.mkdir()
        if populated:
            (work / "build-provenance.json").write_bytes(b'{"old": "receipt"}\n')
            (work / "iphone-final-build.log").write_bytes(b"old native log\x00\xff\n")
            old_app = work / "old-products/Companion.app"
            old_app.mkdir(parents=True)
            (old_app / "Info.plist").write_bytes(b"original bundle bytes\x00\x01")
            (work / "empty-directory").mkdir()
        before = tree_bytes(work)
        args, native, reader = self.fake_build(work=work)
        rejected = False
        try:
            CAPTURE.build(args)
        except (FileExistsError, ValueError):
            rejected = True
        self.assertEqual(tree_bytes(work), before, "A reused build directory was changed")
        self.assertTrue(rejected, "An existing build directory was accepted")
        reader.assert_not_called()
        self.assertEqual(native, [])
        self.run_guard.assert_not_called()
        self.subprocess_guard.assert_not_called()

    def test_populated_build_directory_preserves_every_byte_before_device_lookup(self):
        self.assert_existing_work_is_preserved(populated=True)

    def test_existing_empty_build_directory_is_also_refused(self):
        self.assert_existing_work_is_preserved(populated=False)

    def test_existing_log_is_never_truncated_or_sent_to_a_process(self):
        path = self.folder / "existing.log"
        original = b"retained native evidence\x00\xff\n"
        path.write_bytes(original)
        self.subprocess_guard.side_effect = None
        self.subprocess_guard.return_value = types.SimpleNamespace(returncode=0)
        with self.assertRaises(FileExistsError):
            REAL_RUN_WRAPPER("synthetic-command", log=path)
        self.assertEqual(path.read_bytes(), original)
        self.subprocess_guard.assert_not_called()

    def test_new_log_accepts_output_from_mocked_process(self):
        path = self.folder / "new.log"
        def process(*_arguments, **kwargs):
            kwargs["stdout"].write("synthetic command output\n")
            return types.SimpleNamespace(returncode=0)
        self.subprocess_guard.side_effect = process
        result = REAL_RUN_WRAPPER("synthetic-command", log=path)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "synthetic command output\n")
        self.subprocess_guard.assert_called_once()

    def test_device_name_and_runtime_come_from_live_inventory_not_input_labels(self):
        before = self.devices.read_bytes()
        self.run_guard.side_effect = None
        self.run_guard.return_value = json.dumps(simulator_inventory())
        actual = CAPTURE.read_devices(self.devices)
        for family in ("iphone", "ipad", "watch"):
            self.assertEqual(actual[family], {"simulator_udid": family + "-owned-id", "owner": "issue-469",
                                            "name": "CodexBar-469-Actual-" + family,
                                            "runtime": WATCH_RUNTIME if family == "watch" else IOS_RUNTIME})
        self.assertEqual(self.devices.read_bytes(), before)
        self.run_guard.assert_called_once_with("xcrun", "simctl", "list", "devices", "available", "-j")
        self.subprocess_guard.assert_not_called()

    def test_missing_or_extra_device_family_is_rejected_before_lookup(self):
        inputs = device_inputs()
        missing = copy.deepcopy(inputs); del missing["ipad"]
        extra = dict(inputs, mac=inputs["iphone"])
        self.run_guard.side_effect = None
        self.run_guard.return_value = json.dumps(simulator_inventory())
        for value in (missing, extra, {}, []):
            with self.subTest(value=value):
                self.devices.write_text(json.dumps(value))
                self.run_guard.reset_mock()
                with self.assertRaises(ValueError):
                    CAPTURE.read_devices(self.devices)
                self.run_guard.assert_not_called()

    def test_each_family_requires_a_distinct_owned_simulator(self):
        inputs = device_inputs()
        inputs["watch"]["simulator_udid"] = inputs["iphone"]["simulator_udid"]
        self.devices.write_text(json.dumps(inputs))
        self.run_guard.side_effect = None
        self.run_guard.return_value = json.dumps(simulator_inventory())
        with self.assertRaises(ValueError):
            CAPTURE.read_devices(self.devices)

    def test_unavailable_or_unowned_device_is_rejected(self):
        for failure in ("false-availability", "missing-availability", "foreign-name", "foreign-owner", "missing-id"):
            with self.subTest(failure=failure):
                inventory = simulator_inventory(); inputs = device_inputs()
                actual = inventory["devices"][WATCH_RUNTIME][0]
                if failure == "false-availability": actual["isAvailable"] = False
                if failure == "missing-availability": del actual["isAvailable"]
                if failure == "foreign-name": actual["name"] = "Unrelated personal Watch"
                if failure == "foreign-owner": inputs["watch"]["owner"] = "unrelated-task"
                if failure == "missing-id": inputs["watch"]["simulator_udid"] = "not-present"
                self.devices.write_text(json.dumps(inputs))
                self.run_guard.side_effect = None
                self.run_guard.return_value = json.dumps(inventory)
                with self.assertRaises((ValueError, KeyError)):
                    CAPTURE.read_devices(self.devices)

    def test_capture_propagates_build_six_from_verified_receipt(self):
        args, inventory, _ = self.capture_case()
        CAPTURE.capture(args)
        receipt = json.loads(args.receipt.read_text())
        self.assertEqual(receipt["build"], "6")
        self.assertEqual(receipt["source_commit"], SOURCE)
        self.assertEqual(inventory.call_count, 2)
        self.run_guard.assert_not_called()
        self.subprocess_guard.assert_not_called()

    def test_capture_rejects_stale_build_or_version_before_device_lookup(self):
        for field, value in (("build", "5"), ("version", "2.1.0")):
            with self.subTest(field=field):
                args, inventory, reader = self.capture_case(**{"receipt_" + field: value})
                with self.assertRaises(ValueError):
                    CAPTURE.capture(args)
                self.assertEqual(inventory.call_count, 2)
                reader.assert_not_called()
                self.assertFalse(args.receipt.exists())
                self.run_guard.assert_not_called()

    def test_capture_rejects_mixed_actual_extension_builds_even_if_hashes_match(self):
        actual = inventories()
        actual["watch"]["bundles"][-1]["build"] = "5"
        args, _, reader = self.capture_case(actual=actual)
        with self.assertRaises(ValueError):
            CAPTURE.capture(args)
        reader.assert_not_called()
        self.assertFalse(args.receipt.exists())
        self.run_guard.assert_not_called()

    def test_capture_still_rejects_changed_app_bytes_before_device_lookup(self):
        actual = inventories()
        actual["iphone"]["sha256"] = "f" * 64
        args, _, reader = self.capture_case(actual=actual)
        with self.assertRaises(ValueError):
            CAPTURE.capture(args)
        reader.assert_not_called()
        self.assertFalse(args.receipt.exists())
        self.run_guard.assert_not_called()


if __name__ == "__main__":
    unittest.main()
