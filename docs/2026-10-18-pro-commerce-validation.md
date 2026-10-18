# Local Pro commerce validation

This is the local reproduction procedure for [issue #468](https://github.com/hemsoft-dev/codexbar-ios/issues/468).
It describes the tests and their isolation contract. It does not record a passing
run or qualify a release. Keep the command logs, result bundles and source
manifest for each execution. [Issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470)
owns the complete release qualification against the exact release candidate and
the toolchain pinned in [the function-risk policy](../scripts/function-risk/policy.json).

## Release runner

[Issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) adds the
[explicit phase runner](../scripts/run-pro-release-validation.sh) and
[method manifest](../scripts/pro-release-phases.json). Use `native --output
<fresh-directory>` for the full ordinary suite followed by preparation 1,
native matrix 25, Germany preparation 1 and Germany storefront 1. The runner
creates an owned device, records source/toolchain/binary provenance and checks
built-test discovery against each result. Native hosts use Debug isolation,
ad hoc signing and coverage instrumentation for both build and execution.
The ordinary shared Pro subset is 197 XCTest methods from 22 source files;
the earlier count of 199 included two top-level support functions.

Use the [function-risk commands](../FUNCTION-RISK.md#reproduce) to merge all
five passing unit results before scoring. The [UI procedure](../UI-TESTING.md#complete-release-phases)
requires 51 journeys on each family plus three separate preparation/reset calls.
UI coverage is not part of the earlier unit-risk job. `probe` builds and runs
only the native preparation to diagnose setup; `--build-only` compiles without
executing tests. Neither produces complete qualification. `--supplementary`
allows local Xcode 27.1 diagnostics without changing the 26.6 release pin.

The lower-level commands below remain useful for diagnosis. Keep instrumentation
consistent across every build and execution, use explicit selectors, preserve
first failures and do not reuse a simulator after failed/incomplete cleanup.
The known monthly-finish failures later in this record remain unresolved until
fresh pinned-toolchain evidence establishes their outcome.

## Individual diagnostic commands

Run these commands from the repository root on an issue branch. Replace
`<simulator-id>`, `<derived-data>` and `<results>` with a dedicated disposable
simulator UUID and new local directories. Do not reuse a personal simulator,
erase another task's device, share this test environment with another process,
or run two builds at once. Use an installed iOS runtime compatible with the
selected SDK. Discover device and runtime identifiers with `xcrun simctl list`
when creating the dedicated simulator.

Record the selected Xcode, actual booted runtime, source commit, working-tree
changes and fixture hash with the run. An installed toolchain newer than the
release pin provides local evidence only.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
set -o pipefail
xcodebuild -version
xcrun swift --version
xcrun simctl list devices available
git rev-parse HEAD
git status --short
shasum -a 256 StoreKit/CodexBarPro.storekit
mkdir -p "<results>"
```

The checked-in [native commerce scheme](../CodexBarIOS.xcodeproj/xcshareddata/xcschemes/CodexBarProNativeCommerce.xcscheme)
sets `CODEXBAR_NATIVE_STOREKIT_TEST_HOST=1` for its Debug test action only. The
app's [fixture route](../CodexBarIOS/Services/UITestFixtures.swift) requires a
simulator, creates a UUID storage namespace and prevents the ordinary app root
and its production entitlement listeners from starting. The native tests assert
that this route is active before creating `SKTestSession`.

`CodexBarProNativeCommerce` contains the five native StoreKit test classes and
`ProCommerceNativeJourneyTests`. Every test execution requires explicit
`-only-testing` selectors. Never run an unqualified `test` or
`test-without-building` with this scheme: preparation, Germany and purchase-error
phases require mutually exclusive store settings and separate host processes.
The canonical `CodexBarIOS` scheme skips the five specialized native classes;
`CodexBarProCommerce` selects only the synthetic commerce UI journeys by default.

The [native support code](../CodexBarIOSTests/StoreKitProTestSupport.swift) provides
the real `StoreKitProStoreSource`. Service cases instantiate production
`ProEntitlement` with a UUID-scoped `ProEntitlementCache`; raw adapter diagnostics
do not create that service. The injected service clock uses current dates, a local
monotonic counter and a test-only continuity identifier. It never reads or writes
the production App Group entitlement cache or continuity marker. No receipt or
purchase evidence is seeded into the native service.

The [StoreKit configuration](../StoreKit/CodexBarPro.storekit) must remain a
source-controlled member of the native test target's Copy Bundle Resources
phase. The tests locate it with `Bundle(for:)`. They must not read the developer
checkout through `#filePath`, copy a different configuration into the bundle, or
replace a failed lookup with hard-coded products or prices. Keep the five
`StoreKitPro*.swift` files in the native test target; they require `StoreKitTest`
and are not SwiftPM test sources.

1. Build the native host and tests once for the dedicated simulator. The scheme
   and command keep test execution serial. Simulator signing is intentional.

   ```sh
   xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
     -skipPackagePluginValidation \
     -destination 'platform=iOS Simulator,id=<simulator-id>' \
     -derivedDataPath '<derived-data>/native' \
     -parallel-testing-enabled NO \
     -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
     -only-testing:CodexBarIOSTests/StoreKitProPreparationTests \
     -only-testing:CodexBarIOSTests/StoreKitProStoreSourceTests \
     -only-testing:CodexBarIOSTests/StoreKitProFailureTests \
     -only-testing:CodexBarIOSTests/StoreKitProSubscriptionTests \
     -only-testing:CodexBarIOSTests/StoreKitProStorefrontTests \
     -only-testing:CodexBarIOSUITests/ProCommerceNativeJourneyTests \
     CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
     SWIFT_STRICT_CONCURRENCY=complete \
     build-for-testing 2>&1 | tee '<results>/native-build.log'
   ```

2. Run only the preparation test, then let this XCTest process exit normally.
   Preparation loads all three real local products, checks the storefront and
   empty entitlement history, and attempts no purchase. It deliberately leaves
   the local configuration active with dialogs disabled.

   ```sh
   xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
     -destination 'platform=iOS Simulator,id=<simulator-id>' \
     -derivedDataPath '<derived-data>/native' \
     -parallel-testing-enabled NO \
     -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
     -only-testing:CodexBarIOSTests/StoreKitProPreparationTests/testPrepareLocalStoreKitConfiguration \
     -resultBundlePath '<results>/native-preparation.xcresult' \
     test-without-building 2>&1 | tee '<results>/native-preparation.log'
   ```

3. Start a separate XCTest invocation on the same simulator and built source.
   Do not combine preparation and purchase execution in one process. This
   process boundary is a local StoreKit activation workaround, not an Apple
   purchase API or a reason to ignore failed setup.

   ```sh
   xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
     -destination 'platform=iOS Simulator,id=<simulator-id>' \
     -derivedDataPath '<derived-data>/native' \
     -parallel-testing-enabled NO \
     -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
     -test-timeouts-enabled YES \
     -default-test-execution-time-allowance 90 \
     -maximum-test-execution-time-allowance 120 \
     -only-testing:CodexBarIOSTests/StoreKitProStoreSourceTests \
     -only-testing:CodexBarIOSTests/StoreKitProFailureTests \
     -only-testing:CodexBarIOSTests/StoreKitProSubscriptionTests \
     -resultBundlePath '<results>/native-commerce.xcresult' \
     test-without-building 2>&1 | tee '<results>/native-commerce.log'
   ```

Each execution case resets its owned session, disables dialogs and requires an
empty session history, current entitlements, latest records and unfinished queue
before creating a service or attempting a purchase. Baseline and cleanup checks
wait at most ten monotonic seconds and count unverified records too. Teardown
awaits `stopAndWait()` on every owned service,
cancels and awaits explicit listeners, clears transactions, resets session
settings and removes API-specific simulated errors. It then requires the same
empty StoreKit baseline before deleting the UUID cache directory. A baseline or
cleanup failure is a test failure.

The tests attach `STOREKIT_NATIVE_EVENT` receipts to the result bundle and log.
They compare transaction identity only in memory. The native cases exercise the
three purchases, yearly trial and eligibility, ordinary renewal, pending
approval, Restore, fresh-source history, refund, expiry, renewal metadata,
auto-renew changes, lifetime gating, overlap, billing grace and retry, supported
API errors and an actual disk write failure before transaction finish.
The monthly service case retains its final empty-queue requirement. Separate raw
monthly cases check the actual adapter finish closure with owned passive
listeners and different read/finish ordering. A test-only forwarding recorder
counts original finish calls by purchase/update origin; its extra stream/task hop
is disclosed, and the original unwrapped service case remains. Receipts report
counts, verification state and identity-match Booleans, never raw identities.

The October 18 local runs on Xcode 27.1 build `27A9275` and iOS 27.0 build
`24A434` retain an unresolved monthly finish boundary. The recorded service case
observed one call to the original finish closure enter and return, with no
cancellation or overlap, followed by one
verified unfinished transaction matching the actual purchase delivery. The raw
`testRawMonthlyDeliveryFinishesBeforeAnyQueueReadback` reproduced that result
without `ProEntitlement`: it immediately awaited the original finish closure
after receiving a verified purchase, then observed the same identity unfinished
for ten seconds. Raw controls that awaited queue readback before finishing
cleared the queue. This establishes an observed ordering difference in these
local runs; it does not establish the underlying cause or a general StoreKit
defect. No production pre-read, delay or finish-retry workaround was added.

Preserve both failed service/raw runs and passing controls. The retained run
directories include `native-recording-monthly`, `native-immediate-finish` and
`native-pre-snapshot-raw` under `/tmp/codexbar-468-validation`; each contains its
log and result bundle. The hard empty-queue assertions remain enabled; these
retained isolated runs failed them. The diagnostics do not establish a passing
native matrix or release qualification.

Two fresh-process preparations using the same built tests on installed iOS 26.5
build `23F77` failed while saving the `SKTestSession` configuration and setting
its properties (`SKInternalErrorDomain` code 3), before a purchase. Preserve
`native-26-prepare-first` and `native-26-prepare-second` as setup failures. They
provide no comparison of purchase or finish behavior across those runtimes.

Germany uses two additional process invocations on the same simulator. The first
sets DEU/de_DE without claiming that the running client's storefront changed.
The second requires an actual German `Storefront.current`, native EUR prices
and exact adapter price mapping. It does not establish hot storefront updates.
Run the methods explicitly; do not select the entire preparation class.

```sh
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/native' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSTests/StoreKitProPreparationTests/testPrepareLocalStoreKitGermany \
  -resultBundlePath '<results>/native-germany-preparation.xcresult' \
  test-without-building 2>&1 | tee '<results>/native-germany-preparation.log'

xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/native' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSTests/StoreKitProStorefrontTests/testCatalogUsesPreparedGermanyStorefrontAndLocale \
  -resultBundlePath '<results>/native-germany.xcresult' \
  test-without-building 2>&1 | tee '<results>/native-germany.log'
```

The billing cases enable simulated billing failure before buying monthly and
wait for accelerated automatic renewal. Apple's
[forced-renewal API](https://developer.apple.com/documentation/storekittest/sktestsession/forcerenewalofsubscription(productidentifier:))
leaves billing retry state unchanged. The selected
[ten-second renewal rate](https://developer.apple.com/documentation/storekittest/sktestsession/timerate-swift.enum/onerenewaleverytenseconds)
also gives a ten-second grace period and twenty-second retry period. Recovery
uses the supported
[transaction issue resolution](https://developer.apple.com/documentation/storekittest/sktestsession/resolveissuefortransaction(identifier:))
API and observes the resulting update.

The expiration case also uses the ten-second rate. It disables auto-renew for
the real purchased transaction, requires verified auto-renew-off, and waits for
native expired status and service access denial before checking a fresh source.
On the tested iOS 27.0 runtime, `expireSubscription` changed session flags while
the native status and current entitlement still described an active subscription,
including when that case ran alone in a fresh process. Preserve those failed
diagnostics; the natural-expiration case does not validate that forced-expiry
hook and does not inject an expired record into the service.

For bounded UI implementation checks, the optional
[CodexBarProCommerce scheme](../CodexBarIOS.xcodeproj/xcshareddata/xcschemes/CodexBarProCommerce.xcscheme)
selects the synthetic commerce UI class without adding automatic CI work. Actual
local StoreKit UI journeys use `CodexBarProNativeCommerce` and the native build
from step 1, with their own preparation and explicit method selectors. They are separate from the
final iPhone/iPad light/dark capture matrix, which follows current-head review
and artifact freeze.

```sh
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProCommerce \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/commerce-ui' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  clean build-for-testing 2>&1 | tee '<results>/commerce-ui-build.log'

xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/commerce-ui' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSUITests/ProCommerceJourneyTests \
  -resultBundlePath '<results>/commerce-ui-synthetic.xcresult' \
  test-without-building 2>&1 | tee '<results>/commerce-ui-synthetic.log'
```

The synthetic [commerce fixtures](../CodexBarIOS/Services/ProCommerceFixture.swift)
use injected evidence and isolated storage. Their prices, billing states,
original-purchaser state and command outcomes prove presentation and policy,
not Apple's purchase behavior. Their launch contract requires
`CODEXBAR_UI_TESTS=1`, a UUID `CODEXBAR_UI_TEST_RUN_ID`,
`CODEXBAR_UI_TEST_RESET=1`, a known `CODEXBAR_UI_TEST_SCENARIO`, and
`CODEXBAR_NATIVE_STOREKIT_TEST_HOST=0`. Optional
`CODEXBAR_COMMERCE_ENTRY=settings` or `limit` chooses the user-entry context;
without it, opening Pro requires a user action in the test. The UI driver sets
these values itself.

For the actual local purchase-and-Restore journey, rerun the native preparation
command in its own process immediately beforehand, with new result and log
paths. Native integration teardown has cleared the store, and preparation must
establish the UI run's empty starting state with dialogs disabled. Then run:

```sh
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/native' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSUITests/ProCommerceNativeJourneyTests/testPurchaseAndRestore \
  -resultBundlePath '<results>/commerce-ui-native.xcresult' \
  test-without-building 2>&1 | tee '<results>/commerce-ui-native.log'
```

The `commerce-native-storekit` fixture uses the real adapter and service with
its own UUID disk cache and clock. It does not initialize or mutate
`SKTestSession`, seed an entitlement, start a second live service, or fall back
to synthetic purchase success. The UI journey checks committed lifetime access
and an explicit Restore result. If local StoreKit asks for Apple Account
sign-in, stop and preserve the failure artifacts; diagnose preparation and host
isolation instead of supplying credentials or converting the failure into a
skip. A test result alone is not the required screen recording.

The unavailable-product failure runs through UI automation because the local
runtime can show a system error alert despite `disableDialogs`. The earlier
unit method `testUnavailableProductPurchaseErrorClearsCommandWithoutGrant`
was moved to the UI method below. Its preparation sets and reads back the actual
`Product.PurchaseError.productUnavailable` simulation, verifies an empty store
and exits without purchasing. The UI journey acknowledges the real alert and
requires failure feedback, Free access and usable purchase/Restore controls.

```sh
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/native' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSTests/StoreKitProPreparationTests/testPrepareLocalStoreKitPurchaseFailure \
  -resultBundlePath '<results>/native-purchase-error-preparation.xcresult' \
  test-without-building 2>&1 | tee '<results>/native-purchase-error-preparation.log'

xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarProNativeCommerce \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath '<derived-data>/native' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
     -enableCodeCoverage YES \
  -only-testing:CodexBarIOSUITests/ProCommerceNativeJourneyTests/testPurchaseErrorLeavesFreePlanAndUsableControls \
  -resultBundlePath '<results>/commerce-ui-native-purchase-error.xcresult' \
  test-without-building 2>&1 | tee '<results>/commerce-ui-native-purchase-error.log'
```

After this failure journey, rerun `testPrepareLocalStoreKitConfiguration` in its
own process with new result and log paths. That reset clears the injected error
and restores USA/en_US before another native journey or simulator retention.

Before the final clean build, preserve the native DerivedData directory and
copy its entire `Build/Products` directory, including the generated `.xctestrun`,
to the retained run directory. Keep those native products unchanged for any
remaining preparation invocations. Build the final signed capture artifact with
the `CodexBarProCommerce` clean app/UI `build-for-testing` command above, using a
new `<derived-data>/final-clean-ui` directory and
`<results>/final-clean-ui-build.log`. Never direct that clean build into the
native DerivedData directory. The native scheme includes the unit-test host;
do not freeze its app as the final UI artifact.

Inspect the clean app for inherited `.xctest` contents, record source and bundle
hashes, verify every embedded bundle's signature and privacy manifest, then
freeze a copy. Preserve a failed artifact
and rebuild through Xcode; do not modify or re-sign a finished app to make it
match. Simulator Mach-O `__TEXT,__entitlements` may contain the App Group even
when `codesign` prints an empty entitlement dictionary. Check actual
registration and bundle contents before drawing a conclusion.

Native preparation with `test-without-building` installs or reinstalls the
unit-test host under the app's bundle identifier. For capture of the frozen
artifact, run preparation in a separate process first, then reinstall the exact
frozen clean app and drive a generic UI runner, or bind the UI runner's
`.xctestrun` `TargetApplicationPath` to that frozen app. Verify the runner's
target path before launch: the generated native UI runner normally targets the
native host and can replace a manually reinstalled frozen app. Record the target
path and frozen app hashes with the capture. The stock native UI command above
does not establish execution of the frozen final artifact.

Export attachments and summaries before removing the dedicated simulator:

```sh
xcrun xcresulttool get test-results summary \
  --path '<results>/native-commerce.xcresult' \
  > '<results>/native-commerce-summary.json'
xcrun xcresulttool export attachments \
  --path '<results>/native-commerce.xcresult' \
  --output-path '<results>/native-commerce-attachments'
```

Use the corresponding result path for preparation and each UI invocation. Copy
any recording, app-container evidence and frozen signed app to the retained run
directory before cleanup. After the final actual UI purchase, rerun preparation
in a separate process if the simulator will be retained; it clears the owned
transactions without making another purchase. Once all artifacts have been
copied and the simulator is no longer in use, shut down and remove only the
dedicated device created for this run:

```sh
xcrun simctl shutdown '<simulator-id>'
xcrun simctl delete '<simulator-id>'
```

Local StoreKit transactions use the `.xcode` environment. They cannot establish
production original-purchaser eligibility, live storefront availability,
production billing behavior or Family Sharing. Apple's
[iOS 27.2 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_2-release-notes)
list fixes for delayed intro-eligibility reset (183933307), storefront and
locale changes not reaching `Storefront.updates` (184155259), and purchase error
dialogs appearing when disabled (184255116). The local iOS 27.0 observations
match these boundaries. Initial trial cases poll actual eligibility within a
deadline; Germany starts a new host; purchase errors use real UI automation.
None of these measures proves the affected hot-update path on iOS 27.0.

The adapter maps both a returned `.userCancelled` and a thrown
`StoreKitError.userCancelled` to the canceled outcome. Focused adapter tests
exercise both paths and require unrelated errors to remain errors. The native
cancellation test records the normalized outcome without claiming which SDK
path produced it; an escaping `StoreKitError.userCancelled` fails the test.
The local iOS 27 runtime can instead return `StoreKitError.unknown` for that
simulation. That framework limitation does not prove cancellation handling.
StoreKitTest's global
verification failure cannot independently represent every transaction and
renewal-info verification combination. The subscription-status simulation reads
back its configured error, queries the native status API directly and requires
the adapter to agree with that response. If the API returns statuses instead of
throwing, the receipt says so; that result does not establish a native status
failure path. The [pure commerce tests](../ProEntitlementTests/ProCommercePolicyTests.swift)
cover those injected cases, preserved renewal prices, unavailable currency and
scheduled next-plan differences. Report that distinction with the native
results. Do not dispatch the full release workflow for these local checks or
change automatic PR CI workloads.

The focused verification tests also recreate the service from actual cache
bytes after lifetime or original-purchaser verification fails. Payment must
remain unavailable until verified evidence resolves that uncertainty. Separate
Restore tests distinguish newly found, qualifying verified purchases from
permitted cached access: an empty Restore reports no purchases without removing
an otherwise valid offline allowance. These injected regressions do not claim
live Apple Account switching or production receipt verification.
