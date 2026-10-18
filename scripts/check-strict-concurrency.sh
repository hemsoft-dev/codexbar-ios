#!/bin/bash

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# The local audit supplies an isolated path so clean never touches developer builds.
run_xcodebuild() {
  if [[ -n "${STRICT_CONCURRENCY_DERIVED_DATA_PATH:-}" ]]; then
    xcodebuild -derivedDataPath "$STRICT_CONCURRENCY_DERIVED_DATA_PATH" "$@"
  else
    xcodebuild "$@"
  fi
}

run_xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarIOS \
  -skipPackagePluginValidation \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  clean build

ios_test_log="$(mktemp -t codexbar-strict-ios-tests)"
watch_test_log="$(mktemp -t codexbar-strict-watch-tests)"
trap 'rm -f "$ios_test_log" "$watch_test_log"' EXIT

check_watch_connectivity_diagnostics() {
  local log_file="$1"
  if grep -E \
    '(WatchSnapshotCoordinator|WatchDashboardSnapshot|WatchConnectivityStore|DashboardAndSettingsTests|WatchDashboardStateTests)\.swift:[0-9]+:[0-9]+: (warning|error):' \
    "$log_file"; then
    echo "Strict-concurrency diagnostics found in WatchConnectivity sources or tests." >&2
    return 1
  fi
}

if ! run_xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarIOS \
  -skipPackagePluginValidation \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing >"$ios_test_log" 2>&1; then
  cat "$ios_test_log"
  exit 1
fi
check_watch_connectivity_diagnostics "$ios_test_log"

if ! run_xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarWatchTests \
  -skipPackagePluginValidation \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing >"$watch_test_log" 2>&1; then
  cat "$watch_test_log"
  exit 1
fi
check_watch_connectivity_diagnostics "$watch_test_log"
