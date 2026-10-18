#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Reuse the native SwiftPM module, not another worktree's build products.
xcrun swift build --target CodexBarIOS
bin_path="$(xcrun swift build --show-bin-path)"
if [[ -f "$bin_path/CodexBarIOS.o" && -d "$bin_path/CodexBarIOS.swiftmodule" ]]; then
  module_path="$bin_path"
  object_files=("$bin_path/CodexBarIOS.o" "$bin_path/ProClockSupport.o")
else
  module_path="$bin_path/Modules"
  object_files=("$bin_path"/CodexBarIOS.build/*.swift.o "$bin_path/ProClockSupport.build/ProClockSupport.c.o")
fi
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-widget-layout.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

python3 - "$repo_root" "$probe_dir" <<'PY'
from pathlib import Path
import sys

root, destination = map(Path, sys.argv[1:])
for name in ["CodexBarWidgetModels", "CodexBarWidgetConfiguration", "CodexBarWidgetViews"]:
    source = (root / "CodexBarIOSWidget" / (name + ".swift")).read_text()
    if name == "CodexBarWidgetViews":
        # Compile the tile and its private visualizations without widget previews
        # or the extension entry point. Keep layout code identical to production.
        source = source[source.index("struct ProviderWidgetTile:"):].split("#Preview(")[0]
        source = "import SwiftUI\nimport WidgetKit\n" + source
        source = source.replace("Color(.systemBackground)", "Color(nsColor: .windowBackgroundColor)")
    (destination / (name + ".swift")).write_text("@testable import CodexBarIOS\n" + source)
PY

xcrun swiftc -swift-version 6 -I "$module_path" -I "$repo_root/ProClockSupport/include" \
  "$probe_dir"/*.swift scripts/tests/widget-reset-layout-probe.swift \
  "${object_files[@]}" -o "$probe_dir/probe"
"$probe_dir/probe"
