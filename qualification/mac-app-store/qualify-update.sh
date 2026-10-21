#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/build/CodexBar Qualification.app"
[[ -d "$app" ]] || { echo 'Run build.sh first' >&2; exit 1; }
stage="$(mktemp -d "$PWD/build/update.XXXXXX")"
# Copies stay in build/. Never replace an installed or store-managed application.
ditto "$app" "$stage/version1.app"
ditto "$app" "$stage/version2.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$stage/version2.app/Contents/Info.plist"
if codesign --verify --strict "$stage/version2.app" 2> "$stage/tamper.txt"; then
  echo 'FAIL modified bundle unexpectedly validated' >&2
  exit 1
fi
echo 'PASS metadata tamper rejected'
codesign --force --sign - --entitlements Qualification.entitlements "$stage/version2.app"
codesign --verify --strict "$stage/version2.app"
ditto "$stage/version2.app" "$stage/installed.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/installed.app/Contents/Info.plist")" == 2 ]]
codesign --verify --strict "$stage/installed.app"
echo 'PASS staged ad hoc version 2 replacement verifies'
rm -rf "$stage/installed.app"
ditto "$stage/version1.app" "$stage/installed.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/installed.app/Contents/Info.plist")" == 1 ]]
codesign --verify --strict "$stage/installed.app"
echo 'PASS staged rollback to version 1 verifies'
echo 'NOT-RUN App Store delivery, publisher signing, store update, receipt preservation'
printf 'Evidence directory: %s\n' "$stage"
