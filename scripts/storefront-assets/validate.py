#!/usr/bin/env python3
"""Validate the local 2.0 storefront manifest and native composition evidence."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
import zlib


SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752), "watch": (422, 514)}
SCENES = {
    "01_free-overview_light": ("free-overview", "light", "synthetic-free", "Free plan", "One account. 7-day history."),
    "02_dashboard-overview_light": ("dashboard-overview", "light", "synthetic-pro", "CodexBar Pro", "All your accounts, together."),
    "03_widget-builder_light": ("widget-builder", "light", "synthetic-pro", "CodexBar Pro", "Build your own widgets."),
    "04_history_dark": ("history", "dark", "synthetic-pro", "CodexBar Pro", "See 90 days of usage."),
}
WATCH = ("overview", "dark", "synthetic-pro-watch-layout", "CodexBar Pro", "On your wrist.")


class ValidationError(ValueError):
    """A storefront asset or its evidence violates the capture contract."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(path.read_text(), object_pairs_hook=unique_keys)


def asset_path(root, relative):
    require(isinstance(relative, str) and not Path(relative).is_absolute(), "Asset paths must be relative")
    path = (root / relative).resolve()
    require(path.is_relative_to(root.resolve()), f"Path escapes artifact root: {relative}")
    return path


def validate_manifest(manifest):
    require(manifest.get("schema_version") == 1 and manifest.get("release") == "2.0.0", "Unsupported manifest")
    assets = manifest.get("assets", [])
    expected = {f"{device}_{scene}": (device, definition) for device in ("iphone", "ipad") for scene, definition in SCENES.items()}
    expected["watch_01_overview"] = ("watch", WATCH)
    identifiers = [asset.get("id") for asset in assets]
    require(len(identifiers) == len(set(identifiers)), "Duplicate asset IDs")
    require(set(identifiers) == set(expected), "Expected four iPhone, four iPad and one Watch scene")
    for asset in assets:
        identifier = asset["id"]
        device, definition = expected[identifier]
        require(asset.get("device") == device, f"Wrong device: {identifier}")
        require((asset.get("width"), asset.get("height")) == SIZES[device], f"Wrong dimensions: {identifier}")
        fields = ("scene", "appearance", "entitlement_fixture", "caption", "subtitle")
        require(tuple(asset.get(field) for field in fields) == definition, f"Wrong scene, plan or caption: {identifier}")
        for field, folder in (("raw_path", "raw"), ("output_path", "screenshots")):
            require(asset.get(field) == f"release-assets/2.0.0/{folder}/{identifier}.png", f"Wrong {field}: {identifier}")
    return assets


def png_info(path):
    data = path.read_bytes()
    require(data[:8] == b"\x89PNG\r\n\x1a\n", f"Not a PNG: {path}")
    offset = 8
    header = None
    image_data = False
    finished = False
    while offset < len(data):
        require(offset + 12 <= len(data), f"Truncated PNG chunk: {path}")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 8 + length
        require(end + 4 <= len(data), f"Truncated PNG payload: {path}")
        payload = data[offset + 8:end]
        checksum = struct.unpack(">I", data[end:end + 4])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == checksum, f"PNG CRC mismatch: {path}")
        if offset == 8:
            require(kind == b"IHDR" and length == 13, f"Missing PNG header: {path}")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IHDR":
            raise ValidationError(f"Duplicate PNG header: {path}")
        elif kind == b"IDAT":
            image_data = True
        elif kind == b"IEND":
            require(length == 0 and end + 4 == len(data), f"Unexpected trailing PNG data: {path}")
            finished = True
        elif kind == b"tRNS":
            raise ValidationError(f"PNG transparency is forbidden: {path}")
        offset = end + 4
    require(header is not None and image_data and finished, f"Incomplete PNG: {path}")
    width, height, depth, color_type, compression, filtering, interlace = header
    require(width > 0 and height > 0, f"Empty PNG: {path}")
    require(depth == 8 and color_type == 2, f"Expected opaque RGB8 PNG: {path}")
    require(compression == 0 and filtering == 0 and interlace in (0, 1), f"Unsupported PNG encoding: {path}")
    return {"width": width, "height": height, "bit_depth": depth, "color_type": "RGB8", "sha256": sha256(path)}


def validate_geometry(geometry, width, height):
    source = geometry.get("source_rect")
    require(source == {"x": 0, "y": 0, "width": width, "height": height}, "Source viewport was cropped")
    require(geometry.get("cropped") is False, "Composition claims a cropped viewport")
    rectangles = {}
    for field in ("screenshot_rect", "caption_rect", "subtitle_rect"):
        rect = geometry.get(field, {})
        require(set(rect) == {"x", "y", "width", "height"}, f"Missing geometry: {field}")
        require(all(isinstance(value, (int, float)) and math.isfinite(value) for value in rect.values()), f"Invalid geometry: {field}")
        require(rect["x"] >= 0 and rect["y"] >= 0 and rect["width"] > 0 and rect["height"] > 0, f"Invalid rectangle: {field}")
        require(rect["x"] + rect["width"] <= width + 1e-6 and rect["y"] + rect["height"] <= height + 1e-6, f"Rectangle outside canvas: {field}")
        rectangles[field] = rect
    screen = rectangles["screenshot_rect"]
    scale = geometry.get("scale")
    require(isinstance(scale, (int, float)) and 0 < scale <= 1, "Invalid screenshot scale")
    require(math.isclose(screen["width"] / width, scale, abs_tol=1e-8), "Screenshot width was stretched")
    require(math.isclose(screen["height"] / height, scale, abs_tol=1e-8), "Screenshot height was stretched")
    for field in ("caption_rect", "subtitle_rect"):
        label = rectangles[field]
        require(label["y"] + label["height"] < screen["y"], "Caption overlaps app controls")
    caption, subtitle = rectangles["caption_rect"], rectangles["subtitle_rect"]
    require(caption["y"] + caption["height"] < subtitle["y"], "Caption and subtitle overlap")


def compare_provenance_fields(actual, expected, fields, message):
    require(isinstance(actual, dict) and isinstance(expected, dict), message)
    require(all(field in actual and field in expected and actual[field] == expected[field] for field in fields), message)


def validate_evidence(assets, provenance, report, root, manifest_path, provenance_path, expected_commit=None):
    commit = provenance.get("source_commit", "")
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Expected full source commit SHA")
    if expected_commit is not None:
        require(commit == expected_commit, "Capture is not from the expected source commit")
    require(str(provenance.get("build", "")).isdigit() and int(provenance["build"]) >= 5, "Expected build 5 or newer")
    require(isinstance(provenance.get("xcode"), str) and provenance["xcode"].strip(), "Missing Xcode version")
    require(report.get("schema_version") == 1, "Unsupported report")
    for field in ("source_commit", "build", "xcode"):
        require(report.get(field) == provenance[field], f"Report {field} differs from capture")
    require(report.get("caption_manifest_sha256") == sha256(manifest_path), "Caption manifest hash differs")
    require(report.get("capture_provenance_sha256") == sha256(provenance_path), "Capture provenance hash differs")
    require(report.get("composition_tool_sha256") == sha256(Path(__file__).with_name("compose.swift")), "Composition tool hash differs")
    composed = report.get("assets", [])
    report_ids = [entry.get("asset", {}).get("id") for entry in composed]
    require(len(report_ids) == len(set(report_ids)), "Duplicate composition report IDs")
    require(set(report_ids) == {asset["id"] for asset in assets}, "Composition report does not match manifest")
    require(set(provenance.get("captures", {})) == set(report_ids), "Capture set does not match manifest")
    by_id = {entry["asset"]["id"]: entry for entry in composed}
    verified = []
    for asset in assets:
        identifier = asset["id"]
        entry = by_id[identifier]
        require(entry["asset"] == asset, f"Report asset differs: {identifier}")
        capture = provenance["captures"][identifier]
        require(capture.get("source_commit") == commit, f"Capture source differs: {identifier}")
        for field in ("scene", "appearance", "entitlement_fixture"):
            require(capture.get(field) == asset[field], f"Capture {field} differs: {identifier}")
        require(isinstance(capture.get("captured_at"), str) and capture["captured_at"].strip(), f"Missing capture timestamp: {identifier}")
        device = provenance.get("devices", {}).get(asset["device"], {})
        require(all(isinstance(device.get(field), str) and device[field].strip() for field in ("name", "simulator_udid", "runtime")), f"Missing native device provenance: {identifier}")
        compare_provenance_fields(entry.get("device"), device, ("name", "simulator_udid", "runtime"),
                                  f"Report native device provenance differs: {identifier}")
        compare_provenance_fields(entry.get("capture"), capture,
                                  ("source_commit", "raw_sha256", "scene", "appearance", "entitlement_fixture", "captured_at"),
                                  f"Report native capture provenance differs: {identifier}")
        raw = png_info(asset_path(root, asset["raw_path"]))
        output = png_info(asset_path(root, asset["output_path"]))
        for image in (raw, output):
            require((image["width"], image["height"]) == (asset["width"], asset["height"]), f"PNG dimensions differ: {identifier}")
        require(raw["sha256"] == capture.get("raw_sha256") == entry.get("raw_sha256"), f"Raw hash differs: {identifier}")
        require(output["sha256"] == entry.get("output_sha256"), f"Output hash differs: {identifier}")
        require(entry.get("png_color_type") == "RGB8", f"Report pixel format differs: {identifier}")
        validate_geometry(entry.get("geometry", {}), asset["width"], asset["height"])
        verified.append({"id": identifier, "raw": raw, "output": output})
    return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--manifest-only", action="store_true", help="Validate captions and paths before captures exist")
    parser.add_argument("--provenance", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--source-commit", help="Require this full source SHA")
    args = parser.parse_args()
    try:
        assets = validate_manifest(load_json(args.manifest))
        if args.manifest_only:
            print(f"Validated {len(assets)} planned captions and native dimensions. No images or capture evidence inspected.")
            return 0
        require(args.provenance is not None and args.report is not None, "--provenance and --report are required for image validation")
        verified = validate_evidence(assets, load_json(args.provenance), load_json(args.report), args.root.resolve(),
                                     args.manifest, args.provenance, args.source_commit)
        print(json.dumps({"status": "passed", "assets": verified, "visual_inspection": "Separate human inspection required"}, indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Storefront validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
