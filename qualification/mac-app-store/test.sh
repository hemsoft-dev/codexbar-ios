#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Keep the result bundle immutable; use a new name for every run.
result="$PWD/build/storekit-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project MacQualification.xcodeproj -scheme MacQualification \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 1 \
  -derivedDataPath "$PWD/build/DerivedData" -resultBundlePath "$result" test
