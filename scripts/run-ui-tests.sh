#!/usr/bin/env bash

# Run both simulator families by default, or select iphone/ipad explicitly.
# Each invocation retains its xcresult, log, summary, and failure attachments.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device_family="${1:-all}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [all|iphone|ipad]" >&2
  exit 2
fi

case "$device_family" in
  all)
    if [[ -n "${UI_TEST_DEVICE_NAME:-}" || -n "${UI_TEST_DEVICE_ID:-}" ]]; then
      echo "Pass iphone or ipad when setting a device override." >&2
      exit 2
    fi
    exit_status=0
    for family in iphone ipad; do
      "$repo_root/scripts/run-ui-tests.sh" "$family" || exit_status=1
    done
    exit "$exit_status"
    ;;
  iphone) device_prefix="iPhone" ;;
  ipad) device_prefix="iPad" ;;
  *) echo "Usage: $0 [all|iphone|ipad]" >&2; exit 2 ;;
esac

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "${UI_TEST_REQUIRE_DEVICE_ID:-0}" == 1 && -z "${UI_TEST_DEVICE_ID:-}" ]]; then
  echo "Release UI execution requires its newly owned simulator UUID." >&2
  exit 1
fi
simulator_json="$(xcrun simctl list --json)"
device="$(jq -r \
  --arg sdk_version "$sdk_version" \
  --arg device_prefix "$device_prefix" \
  --arg preferred_name "${UI_TEST_DEVICE_NAME:-}" \
  --arg preferred_id "${UI_TEST_DEVICE_ID:-}" '
    def version_components:
      split(".") | map(tonumber) | (. + [0, 0, 0])[:3];
    . as $simulators
    | ($sdk_version | version_components) as $sdk
    | [
        .runtimes[]
        | select(.isAvailable == true
            and (.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-")))
        | (.version | version_components) as $version
        | select($version <= $sdk)
        | .identifier as $runtime
        | $simulators.devices[$runtime][]?
        | . as $device
        | select(.isAvailable == true)
        | select(any($simulators.devicetypes[];
            .identifier == $device.deviceTypeIdentifier and (.name | startswith($device_prefix))))
        | select($preferred_name == "" or .name == $preferred_name)
        | select($preferred_id == "" or .udid == $preferred_id)
        | {name, udid, version: $version}
      ]
    | sort_by(.version, .name, .udid) | last
    | if . == null then empty else [.udid, .name] | @tsv end
  ' <<< "$simulator_json")"

if [[ -z "$device" ]]; then
  echo "No matching $device_prefix simulator is compatible with iOS SDK $sdk_version." >&2
  xcrun simctl list runtimes available >&2
  xcrun simctl list devices available >&2
  exit 1
fi

IFS=$'\t' read -r device_id device_name <<< "$device"
results_root="${UI_TEST_RESULTS_DIR:-$repo_root/build/ui-tests}"
mkdir -p "$results_root"
results_root="$(cd "$results_root" && pwd)"
run_dir="$(mktemp -d "$results_root/$device_family.XXXXXX")"
result_bundle="$run_dir/CodexBarIOSUITests.xcresult"
echo "Running UI journeys on $device_name ($device_id). Results: $run_dir"

# Preserve xcodebuild's exit status even if diagnostic extraction fails.
preserve_failure_attachments() {
  local exit_status=$?
  if [[ $exit_status -ne 0 && -d "$result_bundle" ]]; then
    xcrun xcresulttool export attachments \
      --path "$result_bundle" \
      --output-path "$run_dir/failure-attachments" || true
  fi
  exit "$exit_status"
}
trap preserve_failure_attachments EXIT

# The manifest selects the original 29 by exact method identity. The four
# FreeTierJourneyTests and two newer Grok methods run in ui-supplemental; the
# 16 commerce journeys and marketing capture cannot leak into this phase.
# The runner builds into fresh DerivedData under run_dir, enumerates the built
# tests, and retains command/source/binary/result evidence even on failure.
python3 "$repo_root/scripts/pro_release_runner.py" base \
  --family "$device_family" --device "$device_id" --output "$run_dir"

# All twenty-nine named UI journeys must run on each destination. A skipped or empty
# suite can otherwise make xcodebuild return success without testing the flows.
if ! jq -e '
  .result == "Passed"
  and .totalTestCount == 29
  and .passedTests == 29
  and .failedTests == 0
  and .skippedTests == 0
  and .expectedFailures == 0
' "$run_dir/summary.json" > /dev/null; then
  cat "$run_dir/summary.json" >&2
  echo "Expected all twenty-nine UI journeys to pass with zero skips on $device_name." >&2
  exit 1
fi
