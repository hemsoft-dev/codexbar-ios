#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/build/CodexBar Qualification.app"
[[ -d "$app" ]] || { echo 'Run build.sh first' >&2; exit 1; }
stage="$(mktemp -d "$PWD/build/update.XXXXXX")"
# Only private copies in this newly owned directory are exchanged. No installed
# application, production receipt, publisher identity or updater is exercised.
ditto "$app" "$stage/version1.app"
ditto "$app" "$stage/version2.app"
printf 'version1-only\n' > "$stage/version1.app/Contents/Resources/Version1Only.txt"
printf 'version2-only\n' > "$stage/version2.app/Contents/Resources/Version2Only.txt"
codesign --force --sign - --entitlements Qualification.entitlements "$stage/version1.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$stage/version2.app/Contents/Info.plist"
if codesign --verify --strict "$stage/version2.app" 2> "$stage/tamper.txt"; then
  echo 'FAIL modified bundle unexpectedly validated' >&2
  exit 1
fi
echo 'PASS metadata tamper rejected'
codesign --force --sign - --entitlements Qualification.entitlements "$stage/version2.app"
verify() {
  local bundle="$1" version="$2" absent="$3"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")" == "$version" ]]
  [[ "$(cat "$bundle/Contents/Resources/Version${version}Only.txt")" == "version${version}-only" ]]
  [[ ! -e "$bundle/Contents/Resources/Version${absent}Only.txt" ]]
  codesign --verify --strict "$bundle"
}
swap() {
  # Darwin's atomic exchange requires both existing directories. It cannot pass
  # by copying into an absent destination or merging resource directories.
  python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys
libc = ctypes.CDLL(None, use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
libc.renamex_np.restype = ctypes.c_int
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 2):
    raise OSError(ctypes.get_errno(), 'renamex_np(RENAME_SWAP) failed')
PY
}
verify "$stage/version1.app" 1 2
verify "$stage/version2.app" 2 1
ditto "$stage/version1.app" "$stage/installed.app"
verify "$stage/installed.app" 1 2
echo 'PASS seeded installed version 1 contents and signature'
swap "$stage/installed.app" "$stage/version2.app"
verify "$stage/installed.app" 2 1
verify "$stage/version2.app" 1 2
echo 'PASS atomic local directory exchange replaces existing version 1 with version 2'
swap "$stage/installed.app" "$stage/version2.app"
verify "$stage/installed.app" 1 2
verify "$stage/version2.app" 2 1
echo 'PASS reverse atomic exchange rolls back to version 1 with exact resources'
echo 'NOT-RUN App Store delivery, publisher signing, store update, receipt preservation, updater implementation'
printf 'Evidence directory: %s\n' "$stage"
