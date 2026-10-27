#!/bin/bash
# Universal-binary and publisher-identity rehearsal for the Mac qualification
# bundle. Builds arm64 and x86_64 slices from the same sources as build.sh,
# runs the sandboxed self-test natively and under Rosetta 2, then optionally
# signs disposable copies with the team's existing Apple Development and Apple
# Distribution identities. Nothing is uploaded, installed, registered or
# provisioned. Evidence goes to build/portability-<timestamp>/.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
if [[ -L "$PWD/build" ]]; then
  echo "Refusing symlinked build directory" >&2
  exit 1
fi
out="$PWD/build/portability-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
log="$out/summary.txt"
note() { printf '%s\n' "$*" | tee -a "$log"; }

note "Started $(date '+%Y-%m-%d %H:%M:%S %Z') on $(sw_vers -productVersion) $(sw_vers -buildVersion) $(uname -m)"
note "Toolchain: $(xcodebuild -version | tr '\n' ' ')"

for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "$arch-apple-macos14.0" -F "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    App.swift Authorization.swift Credentials.swift Restore.swift Checks.swift \
    -o "$out/CodexBarQualification-$arch"
done

package() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  lipo -create "$out/CodexBarQualification-arm64" "$out/CodexBarQualification-x86_64" \
    -output "$app/Contents/MacOS/CodexBarQualification"
  cp Info.plist "$app/Contents/Info.plist"
  cp Qualification.storekit "$app/Contents/Resources/Qualification.storekit"
  uuidgen > "$app/Contents/Resources/FixtureNamespace.txt"
}

universal="$out/Universal/CodexBar Qualification.app"
package "$universal"
codesign --force --sign - --entitlements Qualification.entitlements "$universal"
codesign --verify --strict --verbose=2 "$universal" 2>> "$log"
note "Slices: $(lipo -archs "$universal/Contents/MacOS/CodexBarQualification")"
note "Minimum OS per slice: $(vtool -show-build "$universal/Contents/MacOS/CodexBarQualification" | awk '/minos/ {print $2}' | tr '\n' ' ')"

status=0
run_self_test() {
  local label="$1" arch="$2" app="$3"
  local test_log="$out/self-test-$label.log"
  set +e
  # A sandboxed launch can wait indefinitely on a system container decision.
  perl -e 'alarm shift; exec @ARGV' "${SELF_TEST_TIMEOUT:-120}" \
    arch "-$arch" "$app/Contents/MacOS/CodexBarQualification" --self-test > "$test_log" 2>&1
  local code=$?
  set -e
  if [[ "$code" -eq 142 ]]; then note "Self-test $label ($arch): timed out after ${SELF_TEST_TIMEOUT:-120}s"; fi
  local passes
  passes="$(grep -c '^PASS' "$test_log" || true)"
  note "Self-test $label ($arch): exit $code, $passes PASS lines, $(grep '^RESULT' "$test_log" || echo 'no RESULT line')"
  if [[ "$code" -ne 0 ]]; then status=1; fi
}

run_self_test universal-native arm64 "$universal"
run_self_test universal-rosetta x86_64 "$universal"

if [[ "${QUALIFY_PUBLISHER_IDENTITIES:-0}" == "1" ]]; then
  # Caller runs this script through scripts/with-codexbar-keychain.sh.
  keychain="$HOME/Library/Keychains/codexbar-dev.keychain-db"
  for kind in "Apple Development" "Apple Distribution"; do
    slug="$(tr ' A-Z' '-a-z' <<< "$kind")"
    app="$out/$slug/CodexBar Qualification.app"
    # Revoked identities can share a name with the current one, so sign by hash.
    hashes="$(security find-identity -v -p codesigning "$keychain" | grep -v CSSMERR | grep "\"$kind: " | awk '{print $2}' || true)"
    if [[ "$(grep -c . <<< "$hashes")" -ne 1 ]]; then
      note "$kind signing: NOT RUN (need exactly one unrevoked identity, found $(grep -c . <<< "$hashes"))"
      status=1
      continue
    fi
    package "$app"
    if [[ -n "${PUBLISHER_BUNDLE_SUFFIX:-}" ]]; then
      # A separate identifier gives this signature its own sandbox container.
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist).$PUBLISHER_BUNDLE_SUFFIX" "$app/Contents/Info.plist"
      note "$kind copy bundle identifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    fi
    if ! codesign --force --timestamp=none --sign "$hashes" --entitlements Qualification.entitlements "$app" 2>> "$log"; then
      note "$kind signing: FAIL"
      status=1
      continue
    fi
    codesign --verify --strict --verbose=2 "$app" 2>> "$log"
    codesign --display --verbose=2 "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2 | sed 's/^/  /' >> "$log"
    note "$kind signing: PASS (strict verify)"
    codesign --display --entitlements :- "$app" > "$out/$slug-entitlements.plist" 2>/dev/null
    set +e
    spctl --assess --type execute "$app" > "$out/$slug-spctl.txt" 2>&1
    note "$kind Gatekeeper assessment: exit $? ($(tr '\n' ' ' < "$out/$slug-spctl.txt"))"
    set -e
    if [[ "$kind" == "Apple Development" ]]; then
      run_self_test development-native arm64 "$app"
      run_self_test development-rosetta x86_64 "$app"
    fi
  done
fi

note "Finished $(date '+%Y-%m-%d %H:%M:%S %Z'), status $status"
printf '%s\n' "$out"
exit "$status"
