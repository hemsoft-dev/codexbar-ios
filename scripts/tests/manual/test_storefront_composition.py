"""Local contract checks for storefront composition; not part of automatic CI."""

import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("storefront_validation", ROOT / "scripts/storefront-assets/validate.py")
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)


def png_chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def png_bytes(color_type=2):
    header = struct.pack(">IIBBBBB", 2, 3, 8, color_type, 0, 0, 0)
    channels = 4 if color_type == 6 else 3
    payload = zlib.compress((b"\x00" + b"\x80" * 2 * channels) * 3)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", payload) + png_chunk(b"IEND", b"")


class StorefrontCompositionTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "release-assets/2.0.0/captions.json").read_text())
        self.geometry = {
            "source_rect": {"x": 0, "y": 0, "width": 1320, "height": 2868},
            "screenshot_rect": {"x": 132, "y": 440, "width": 1056, "height": 2294.4},
            "caption_rect": {"x": 400, "y": 80, "width": 520, "height": 72},
            "subtitle_rect": {"x": 72, "y": 190, "width": 1176, "height": 184},
            "scale": 0.8,
            "cropped": False,
        }

    def test_manifest_has_nine_plan_disclosed_native_scenes(self):
        self.assertEqual(len(VALIDATION.validate_manifest(self.manifest)), 9)

    def test_pro_screenshot_cannot_be_labelled_free(self):
        self.manifest["assets"][1]["caption"] = "Free plan"
        with self.assertRaisesRegex(VALIDATION.ValidationError, "Wrong scene, plan or caption"):
            VALIDATION.validate_manifest(self.manifest)

    def test_free_screenshot_cannot_use_pro_fixture(self):
        self.manifest["assets"][0]["entitlement_fixture"] = "synthetic-pro"
        with self.assertRaises(VALIDATION.ValidationError):
            VALIDATION.validate_manifest(self.manifest)

    def test_historical_output_directory_is_rejected(self):
        self.manifest["assets"][0]["output_path"] = "release-assets/1.4.0/iphone.png"
        with self.assertRaisesRegex(VALIDATION.ValidationError, "Wrong output_path"):
            VALIDATION.validate_manifest(self.manifest)

    def test_duplicate_asset_cannot_replace_missing_scene(self):
        self.manifest["assets"][-1] = copy.deepcopy(self.manifest["assets"][0])
        with self.assertRaisesRegex(VALIDATION.ValidationError, "Duplicate asset IDs"):
            VALIDATION.validate_manifest(self.manifest)

    def test_proportional_uncropped_viewport_is_accepted(self):
        VALIDATION.validate_geometry(self.geometry, 1320, 2868)

    def test_stretched_viewport_is_rejected(self):
        self.geometry["screenshot_rect"]["width"] -= 100
        with self.assertRaisesRegex(VALIDATION.ValidationError, "stretched"):
            VALIDATION.validate_geometry(self.geometry, 1320, 2868)

    def test_caption_over_app_controls_is_rejected(self):
        self.geometry["subtitle_rect"]["y"] = 400
        with self.assertRaisesRegex(VALIDATION.ValidationError, "overlaps app controls"):
            VALIDATION.validate_geometry(self.geometry, 1320, 2868)

    def test_missing_source_edges_are_rejected(self):
        self.geometry["source_rect"]["height"] -= 40
        with self.assertRaisesRegex(VALIDATION.ValidationError, "cropped"):
            VALIDATION.validate_geometry(self.geometry, 1320, 2868)

    def test_opaque_rgb_png_is_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "rgb.png"
            path.write_bytes(png_bytes())
            result = VALIDATION.png_info(path)
            self.assertEqual((result["width"], result["height"], result["color_type"]), (2, 3, "RGB8"))

    def test_rgba_png_is_rejected_even_when_every_pixel_is_opaque(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "rgba.png"
            path.write_bytes(png_bytes(color_type=6))
            with self.assertRaisesRegex(VALIDATION.ValidationError, "opaque RGB8"):
                VALIDATION.png_info(path)

    def test_corrupt_png_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "corrupt.png"
            data = bytearray(png_bytes())
            data[29] ^= 1
            path.write_bytes(data)
            with self.assertRaisesRegex(VALIDATION.ValidationError, "CRC mismatch"):
                VALIDATION.png_info(path)

    def test_outside_artifact_root_path_is_rejected(self):
        with self.assertRaisesRegex(VALIDATION.ValidationError, "escapes artifact root"):
            VALIDATION.asset_path(ROOT, "../unrelated.png")

    def test_capture_owner_can_retain_extra_native_evidence(self):
        capture = {
            "source_commit": "a" * 40,
            "raw_sha256": "b" * 64,
            "scene": "free-overview",
            "appearance": "light",
            "entitlement_fixture": "synthetic-free",
            "captured_at": "2026-10-18T10:45:00+00:00",
        }
        original = dict(capture, fixture_receipt={"hasProAccess": False}, application_sha256="c" * 64,
                        raw_path="/tmp/assets/raw.png", launch_arguments=["simctl", "launch"])
        VALIDATION.compare_provenance_fields(capture, original, tuple(capture), "Capture provenance differs")
        device = {"name": "iPhone 17 Pro Max", "simulator_udid": "task-owned-uuid", "runtime": "iOS 27.0"}
        original_device = dict(device, owner="issue-469", runtime_system_version={"ProductVersion": "27.0"})
        VALIDATION.compare_provenance_fields(device, original_device, tuple(device), "Device provenance differs")

    def test_required_capture_field_still_must_match(self):
        with self.assertRaisesRegex(VALIDATION.ValidationError, "Capture provenance differs"):
            VALIDATION.compare_provenance_fields({"source_commit": "a" * 40}, {"source_commit": "b" * 40},
                                                 ("source_commit",), "Capture provenance differs")

    def test_missing_required_provenance_field_is_rejected(self):
        with self.assertRaisesRegex(VALIDATION.ValidationError, "Device provenance differs"):
            VALIDATION.compare_provenance_fields({}, {}, ("runtime",), "Device provenance differs")


if __name__ == "__main__":
    unittest.main()
