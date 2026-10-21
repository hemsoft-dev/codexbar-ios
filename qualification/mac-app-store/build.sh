#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
app="$PWD/build/CodexBar Qualification.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$frameworks" \
  -Xlinker -rpath -Xlinker "$frameworks" \
  App.swift Authorization.swift Credentials.swift Restore.swift Checks.swift \
  -o "$app/Contents/MacOS/CodexBarQualification"
cp Info.plist "$app/Contents/Info.plist"
cp Qualification.storekit "$app/Contents/Resources/Qualification.storekit"
uuidgen > "$app/Contents/Resources/FixtureNamespace.txt"
codesign --force --sign - --entitlements Qualification.entitlements "$app"
codesign --verify --strict --verbose=2 "$app"
codesign --display --entitlements :- "$app" > build/signed-entitlements.plist 2> build/signature.txt
printf '%s\n' "$app"
