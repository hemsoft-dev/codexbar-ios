# Storefront image composition

The [2.0 caption manifest](../../release-assets/2.0.0/captions.json) defines four
iPhone images, four iPad images and one Watch overview. Each public image shows
its plan outside the complete native app viewport. The Free plan image uses one
account and seven days of history. All other images require their Pro fixture.

`compose.swift` draws captions with AppKit and fits the entire native screenshot
proportionally below them. It does not replace, crop, repaint or cover app
controls. It writes opaque RGB8 PNGs at the source device's accepted dimensions.
The result is deterministic for the same inputs and macOS font/rendering version.

The capture owner builds and captures the committed source first. Keep logs,
DerivedData and generated evidence outside the repository. `--root` is the
artifact root, and the manifest's relative paths are resolved beneath it. The
manifest and tooling stay in the repository. Never use the historical
1.x image directories as output. The compositor does not build, boot or launch
anything, and does not contact App Store Connect.

Run the compositor with the selected Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift \
  scripts/storefront-assets/compose.swift \
  --manifest release-assets/2.0.0/captions.json \
  --root /tmp/codexbar-469-validation/artifacts \
  --provenance /tmp/codexbar-469-validation/capture-provenance.json \
  --report /tmp/codexbar-469-validation/composition.json
```

Capture provenance uses this shape. The values below describe the schema and
must be replaced with the actual build, commit, device and capture evidence.
Include one capture keyed by each manifest asset ID.

```json
{
  "source_commit": "FULL_40_CHARACTER_COMMITTED_SOURCE_SHA",
  "build": "5",
  "xcode": "ACTUAL_XCODE_VERSION_AND_BUILD",
  "devices": {
    "iphone": {
      "name": "iPhone 17 Pro Max",
      "simulator_udid": "ACTUAL_TASK_OWNED_SIMULATOR_UDID",
      "runtime": "ACTUAL_RUNTIME_VERSION_AND_BUILD"
    }
  },
  "captures": {
    "iphone_01_free-overview_light": {
      "source_commit": "FULL_40_CHARACTER_COMMITTED_SOURCE_SHA",
      "raw_sha256": "ACTUAL_RGB_PNG_SHA256",
      "scene": "free-overview",
      "appearance": "light",
      "entitlement_fixture": "synthetic-free",
      "captured_at": "ACTUAL_ISO8601_CAPTURE_TIME_WITH_TIME_ZONE"
    }
  }
}
```

Add `ipad` and `watch` devices with the same fields. Record app executable and
bundle hashes, signing details, fixture isolation and inspection timestamps in
the capture owner's evidence. Those facts cannot be inferred from PNGs.
The composition report copies capture provenance and records input/output
SHA256 hashes, source and destination rectangles, scale, tool hash, manifest hash
and macOS rendering version. Rectangle coordinates start at the top left.

Validate all images and their composition evidence locally:

```sh
python3 scripts/storefront-assets/validate.py \
  --manifest release-assets/2.0.0/captions.json \
  --root /tmp/codexbar-469-validation/artifacts \
  --provenance /tmp/codexbar-469-validation/capture-provenance.json \
  --report /tmp/codexbar-469-validation/composition.json \
  --source-commit ACTUAL_FULL_SOURCE_SHA
```

Before images exist, pass only `--manifest`, `--root` and `--manifest-only` to
check the planned captions. That mode makes no claim about image evidence.
The local contract checks run with:

```sh
python3 -m unittest discover -s scripts/tests/manual -p test_storefront_composition.py
```

These commands are manual developer checks. They add no automatic CI workload.
Inspect every raw and composed image at full size and thumbnail size. The
validator checks file integrity, geometry and evidence consistency; it cannot
judge whether the app actually displayed the expected state or whether text is
readable. Keep each visual inspection timestamp in the capture evidence.

The three Pro purchase review screenshots belong in a separate review folder.
They must show actual localized values returned by the local StoreKit test
configuration. These public compositions are not purchase review screenshots
and do not establish live App Store Connect product availability.
