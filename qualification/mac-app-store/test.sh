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
mkdir -p build
# A unique directory preserves failures, console output and xcresult on every run.
run="$(mktemp -d "$PWD/build/storekit-$(TZ=America/New_York date +%Y%m%d-%H%M%S)-XXXXXX")"
{
  TZ=America/New_York date '+Started %Y-%m-%d %H:%M:%S %Z'
  echo "DEVELOPER_DIR=$DEVELOPER_DIR"
  xcodebuild -version
  sw_vers
  uname -m
  shasum -a 256 StoreKitTests.swift StoreKitTestHost.swift StoreKitTestHost.entitlements \
    Qualification.storekit MacQualification.xcodeproj/project.pbxproj \
    MacQualification.xcodeproj/xcshareddata/xcschemes/MacQualification.xcscheme
} | tee "$run/environment.txt"
set +e
xcodebuild -project MacQualification.xcodeproj -scheme MacQualification \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 1 \
  -derivedDataPath "$PWD/build/StoreKitDerivedData-$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  -resultBundlePath "$run/TestResults.xcresult" test 2>&1 | tee "$run/xcodebuild.log"
status=${PIPESTATUS[0]}
set -e
{
  TZ=America/New_York date '+Finished %Y-%m-%d %H:%M:%S %Z'
  echo "xcodebuild exit status: $status"
  echo "Evidence: $run"
} | tee -a "$run/environment.txt"
exit "$status"
