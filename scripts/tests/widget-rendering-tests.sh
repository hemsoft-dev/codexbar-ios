#!/bin/bash
# Explicit local-only native rendering evidence. No automatic CI or SwiftPM target changes.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

source_ref=""
output_dir=""
baseline_dir=""
record_only=false
while (($#)); do
  case "$1" in
    --source-ref) source_ref="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --compare-baseline) baseline_dir="$2"; shift 2 ;;
    --record-only) record_only=true; shift ;;
    --help)
      cat <<'HELP'
Usage: scripts/tests/widget-rendering-tests.sh [options]
  --source-ref REF         Stage widget sources from REF, without changing the worktree.
  --record-only            Record failed assertions without returning a failure status.
  --output DIRECTORY      Default: .build/issue-473-evidence/after, or before with --source-ref.
  --compare-baseline DIR   Require identical full-color tile PNGs to this previous capture.

Requires this worktree's already-built CodexBarIOS SwiftPM module. The runner
does not invoke SwiftPM, modify production sources, or dispatch CI.

Evidence uses the actual SwiftUI widget views with injected widget family,
rendering mode, and background visibility. It uses macOS font metrics. The
accented presentation is a native alpha-mask fixture, not a WidgetKit host.
Vibrant captures show source grayscale, not the OS material compositor.
HELP
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$output_dir" ]]; then
  output_dir="$repo_root/.build/issue-473-evidence/after"
  if [[ -n "$source_ref" ]]; then
    output_dir="$repo_root/.build/issue-473-evidence/before"
  fi
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
if [[ -n "$baseline_dir" ]]; then
  baseline_dir="$(cd "$baseline_dir" && pwd)"
fi

mkdir -p "$repo_root/.build"
probe_dir="$(mktemp -d "$repo_root/.build/widget-rendering.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
bundle_dir="$probe_dir/WidgetRenderingProbe.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources" "$probe_dir/sources"

# Swift 6.3's Xcode backend emits one object; earlier SwiftPM versions emit one per source.
if [[ -f .build/debug/CodexBarIOS.o && -d .build/debug/CodexBarIOS.swiftmodule ]]; then
  module_path="$repo_root/.build/debug"
  object_files=("$repo_root/.build/debug/CodexBarIOS.o")
elif [[ -f .build/debug/Modules/CodexBarIOS.swiftmodule ]]; then
  module_path="$repo_root/.build/debug/Modules"
  object_files=("$repo_root"/.build/debug/CodexBarIOS.build/*.swift.o)
else
  echo "Missing worktree-local CodexBarIOS module. Build the SwiftPM CodexBarIOS target first." >&2
  exit 2
fi

python3 - "$repo_root" "$probe_dir" "$output_dir" "$source_ref" <<'PY'
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

root, temporary, output = map(Path, sys.argv[1:4])
reference = sys.argv[4]
manifest = {
    "source": reference or "working tree",
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "limitations": [
        "Native SwiftUI ImageRenderer, macOS font metrics; not the WidgetKit compositor.",
        "Standalone probe disables availability checks to render accessory content marked unavailable as a macOS widget family.",
        "Readonly widgetFamily and showsWidgetContainerBackground keys are substituted only in staged copies.",
        "Accented images use a native SwiftUI alpha mask; vibrant images show opaque grayscale source.",
        "Synthetic provider snapshots only; preview mode prevents loading saved widget choices.",
    ],
    "sources": {},
}
for name in ["CodexBarWidgetModels", "CodexBarWidgetConfiguration", "CodexBarWidgetViews", "CodexBarWidgetAccessoryViews"]:
    relative = f"CodexBarIOSWidget/{name}.swift"
    source = (
        subprocess.check_output(["git", "show", f"{reference}:{relative}"], cwd=root, text=True)
        if reference else (root / relative).read_text()
    )
    manifest["sources"][relative] = hashlib.sha256(source.encode()).hexdigest()
    source = source.split("#Preview(")[0]
    source = source.replace("Color(.systemBackground)", "Color(nsColor: .windowBackgroundColor)")
    source = source.replace(r"\.widgetFamily", r"\.fixtureWidgetFamily")
    source = source.replace(r"\.showsWidgetContainerBackground", r"\.fixtureShowsContainerBackground")
    (temporary / "sources" / f"{name}.swift").write_text("@testable import CodexBarIOS\n" + source)

probe = (root / "scripts/tests/widget-rendering-probe.swift").read_text()
manifest["probe_sha256"] = hashlib.sha256(probe.encode()).hexdigest()
(temporary / "sources/RenderingProbe.swift").write_text(probe)

plist = {
    "CFBundleIdentifier": "com.hemsoft.CodexBar.WidgetRenderingProbe",
    "CFBundleExecutable": "probe",
    "CFBundleName": "WidgetRenderingProbe",
    "CFBundlePackageType": "APPL",
    "LSBackgroundOnly": True,
}
with (temporary / "WidgetRenderingProbe.app/Contents/Info.plist").open("wb") as stream:
    plistlib.dump(plist, stream)
(output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

# The native executable's bundle must contain the same provider assets as the app.
# No raw build log is retained or copied to the evidence directory.
filter_diagnostics() {
  python3 -c 'import re,sys
for line in sys.stdin:
    if re.search(r"environment\s*[:=]|env\s*=|(?:TOKEN|PASSWORD|SECRET|CREDENTIAL|API_KEY)\s*[=:]", line, re.I):
        continue
    sys.stdout.write(line)
'
}

env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
  xcrun actool CodexBarIOS/Resources/Assets.xcassets \
  --compile "$bundle_dir/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-format human-readable-text \
  2>&1 | filter_diagnostics

env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
  xcrun swiftc -swift-version 6 -Xfrontend -disable-availability-checking -I "$module_path" \
  "$probe_dir"/sources/*.swift \
  "${object_files[@]}" -o "$bundle_dir/Contents/MacOS/probe" \
  2>&1 | filter_diagnostics

probe_arguments=("--output" "$output_dir")
if [[ "$record_only" == true ]]; then probe_arguments+=("--record-only"); fi
if [[ -n "$baseline_dir" ]]; then probe_arguments+=("--compare-baseline" "$baseline_dir"); fi
"$bundle_dir/Contents/MacOS/probe" "${probe_arguments[@]}" 2>&1 | filter_diagnostics
