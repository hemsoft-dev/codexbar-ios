#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Xcode 27.1's StoreKitTest purchase encoding fails against macOS 26.6.2 Octane.
# Keep the proven local toolchain explicit; never retry a failed gate on another SDK.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Missing qualified Xcode 26.6. Set DEVELOPER_DIR explicitly to test another toolchain." >&2
  exit 1
fi
# Re-exec the entire three-phase shell under one kernel-held machine-wide lock.
# The internal flag is only used by this wrapper; ordinary callers omit it.
if [[ "${1:-}" != --exclusive-child ]]; then
  exec python3 exclusive-storekit.py /bin/bash "$PWD/test.sh" --exclusive-child
fi
python3 exclusive-storekit.py --check-held
mkdir -p build
# A unique directory preserves failures, console output and xcresult on every run.
run="$(mktemp -d "$PWD/build/storekit-$(TZ=America/New_York date +%Y%m%d-%H%M%S)-XXXXXX")"
{
  TZ=America/New_York date '+Started %Y-%m-%d %H:%M:%S %Z'
  echo "DEVELOPER_DIR=$DEVELOPER_DIR"
  xcodebuild -version
  sw_vers
  uname -m
  shasum -a 256 test.sh exclusive-storekit.py generate-project.py Restore.swift StoreKitTests.swift StoreKitTestHost.swift StoreKitTestHost.entitlements \
    Qualification.storekit MacQualification.xcodeproj/project.pbxproj \
    MacQualification.xcodeproj/xcshareddata/xcschemes/MacQualification.xcscheme
} | tee "$run/environment.txt"
status=0
for phase in ordinary prepare relaunch; do
  case "$phase" in
    ordinary) selectors=(-skip-testing:StoreKitQualificationTests/StoreKitQualificationTests/testPrepareLifetimeForRelaunch -skip-testing:StoreKitQualificationTests/StoreKitQualificationTests/testRestoreLifetimeAfterRelaunch) ;;
    prepare) selectors=(-only-testing:StoreKitQualificationTests/StoreKitQualificationTests/testPrepareLifetimeForRelaunch) ;;
    relaunch) selectors=(-only-testing:StoreKitQualificationTests/StoreKitQualificationTests/testRestoreLifetimeAfterRelaunch) ;;
  esac
  set +e
  xcodebuild -project MacQualification.xcodeproj -scheme MacQualification \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 1 \
    -derivedDataPath "$PWD/build/StoreKitDerivedData-$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    -resultBundlePath "$run/$phase.xcresult" "${selectors[@]}" test 2>&1 | tee "$run/$phase.log"
  # Snapshot both statuses in one assignment before any command overwrites them.
  phase_statuses=("${PIPESTATUS[@]}")
  status=${phase_statuses[0]}
  if [[ "${phase_statuses[1]}" != 0 ]]; then
    echo "$phase logging failed: tee exit status ${phase_statuses[1]} (xcodebuild ${phase_statuses[0]})" >&2
    [[ "$status" != 0 ]] || status=${phase_statuses[1]}
  fi
  set -e
  [[ "$status" == 0 ]] || break
done
set +e
{
  TZ=America/New_York date '+Finished %Y-%m-%d %H:%M:%S %Z'
  echo "qualification exit status: $status"
  echo "Evidence: $run"
} | tee -a "$run/environment.txt"
metadata_statuses=("${PIPESTATUS[@]}")
set -e
for metadata_status in "${metadata_statuses[@]}"; do
  if [[ "$metadata_status" != 0 ]]; then
    echo "Final metadata write failed: exit status $metadata_status; qualification status $status" >&2
    [[ "$status" != 0 ]] || status=$metadata_status
  fi
done
exit "$status"
