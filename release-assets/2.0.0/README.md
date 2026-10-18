# CodexBar 2.0 storefront assets

[Issue #469](https://github.com/hemsoft-dev/codexbar-ios/issues/469) prepares
nine public images and three product review screenshots. The
[caption manifest](captions.json) specifies four scenes on iPhone 17 Pro Max at
1320 × 2868, four on iPad Pro 13-inch M5 at 2064 × 2752, and one native Apple
Watch Ultra 3 overview at 422 × 514. These are accepted sizes in Apple's
[screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

The Free plan scene has one account and seven-day history. The other scenes
have synthetic Pro access and a visible CodexBar Pro label in the public image.
History opens at 90 days. Widget Builder shows the app's widget preview, not an
installed Home Screen widget. Watch shows the native companion with sample
usage, not a watch-face complication or a live phone-to-Watch synchronization.
The captions sit outside the complete app viewport. Composition scales the
viewport proportionally and never crops it or paints over controls.

The public fixtures use UUID-isolated defaults, in-memory sample credentials
and entitlement evidence. They do not request provider data, consult a live
purchase account or publish to the production widget/Watch stores. The capture
readiness receipt checks resolved access, account count and history policy.
The three reviewer images instead use the production StoreKit source against
[CodexBarPro.storekit](../../StoreKit/CodexBarPro.storekit). Their prices are
local test values, not evidence of live App Store Connect products.

## Source and artifact identity

Commit all source, metadata and tooling before the final clean build. Keep
DerivedData, result bundles, generated PNGs and receipts outside the checkout.
The generated tree still uses `release-assets/2.0.0/raw`, `screenshots` and
`review` beneath its artifact root. This preserves the exact capture source
commit without making another commit solely to add generated images.
Historical [1.4.0 assets](../1.4.0/README.md) remain unchanged.

[`capture-storefront-assets.py`](../../scripts/capture-storefront-assets.py)
requires a clean issue branch and explicit task-owned device IDs. It uses an
allowlisted environment for native commands, verifies the final app contains no
unit-test bundle, checks embedded versions and signatures, hashes every bundle
file, and compares the installed app with that build. It never selects, erases
or deletes a simulator and never contacts App Store Connect. Xcode uses only
ad hoc simulator signatures. No signing keychain or developer identity is used.

Create disposable devices named `CodexBar-469-iPhone`, `CodexBar-469-iPad` and
`CodexBar-469-Watch` with `simctl create` and the installed compatible runtimes.
Record the returned IDs in a JSON file keyed `iphone`, `ipad` and `watch`. Each
entry requires `simulator_udid`, `name`, `runtime` and `owner: "issue-469"`.
The capture command adds the actual runtime build from the booted simulator.
Do not reuse the IDs of unrelated or historical capture devices.

Use a credential-free native command wrapper for preparation and manual tools:

```sh
native() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$@"
}
```

The paths below assume `/tmp/codexbar-469-validation` is a fresh run directory.
Keep failed attempts in distinct paths; do not overwrite their receipts.

## Native preparation and focused checks

Use the existing [native StoreKit preparation procedure](../../docs/2026-10-18-pro-commerce-validation.md)
in a separate DerivedData directory and process before the product screenshots.
Run only `StoreKitProPreparationTests/testPrepareLocalStoreKitConfiguration`.
Require three returned products, USA storefront and empty transactions. This
step performs no purchase. Never substitute the native test host for the final
capture app, since it contains the unit-test bundle.

The focused unit class `StorefrontFixtureTests` verifies the new Free and Pro
fixtures through the actual plan coordinator. Run its two tests locally with
an isolated test host. The main iOS unit scheme includes it. For an already built isolated native
host, copy the generated unit `.xctestrun` beside the original, remove its UI
test entry, and set the unit entry's `OnlyTestIdentifiers` to
`["StorefrontFixtureTests"]`. Keep `CODEXBAR_NATIVE_STOREKIT_TEST_HOST=1`,
all original product paths and a serial run. Require exactly two passes and
zero skips. The specialized native scheme keeps its existing selected-test
list. It is not an automatic
pull-request workload. Do not run the broader commerce matrix for asset work.

The four known monthly transaction-finish failures described in the
[commerce validation record](../../docs/2026-10-18-pro-commerce-validation.md)
remain [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) release
qualification work. Local product screenshots neither resolve nor waive them.

## Build and capture the committed source

```sh
python3 scripts/capture-storefront-assets.py build \
  --devices /tmp/codexbar-469-validation/devices.json \
  --work-dir /tmp/codexbar-469-validation/final

python3 scripts/capture-storefront-assets.py capture \
  --devices /tmp/codexbar-469-validation/devices.json \
  --build-receipt /tmp/codexbar-469-validation/final/build-provenance.json \
  --manifest release-assets/2.0.0/captions.json \
  --output-root /tmp/codexbar-469-validation/artifacts \
  --receipt /tmp/codexbar-469-validation/capture-provenance.json
```

The build action runs clean iOS app/UI and Watch builds with complete strict
concurrency and Swift warnings as errors. The capture action waits for each
fresh scene's readiness marker, keeps the original simulator PNG separately,
and flattens an opaque RGB copy at the same dimensions. The source SHA, runtime,
app hashes, fixture receipt and image hashes are retained with the capture.

Run the [native compositor and validator](../../scripts/storefront-assets/README.md)
against the same artifact root. Their geometry report records the full source
rectangle and proportional destination rectangle. Inspect all nine raw and
composed images at native size and thumbnail scale. Record the inspection time
and hash for each image. A valid manifest alone is not visual inspection.

## Three product review screenshots

The manual `CodexBarStorefrontAssets` scheme selects only
[`StorefrontReviewCaptureTests`](../../CodexBarIOSUITests/StorefrontReviewCaptureTests.swift).
It launches the isolated `commerce-native-storekit` route at Settings > CodexBar
Pro, verifies the resolved Free plan and native localized prices, and scrolls
each product's complete card into view. The UI offers a separate purchase
button on each card rather than a selected-plan control. These screenshots
show monthly, yearly and lifetime respectively without starting a purchase.

After successful native preparation, use the clean final iOS `.xctestrun` from
`final/iphone-final-build/Build/Products` with `test-without-building`, serial
execution and the task-owned iPhone destination. Select only
`CodexBarIOSUITests/StorefrontReviewCaptureTests/testCaptureThreeLocalStoreKitProducts`.
Verify its `UITargetAppPath` points to the clean final app. Do not use the
native preparation host's `.xctestrun` for this capture. Preserve and compare the
final app hash before and after the UI invocation.

Export the result's attachments with `xcresulttool export attachments`. Keep
`review-monthly`, `review-yearly` and `review-lifetime` screenshots and their
accessibility text. Flatten the native PNGs to opaque RGB without changing their
1320 × 2868 viewport, into `release-assets/2.0.0/review`. Record original and
flattened hashes plus the local StoreKit configuration hash. Inspect all three
images; the corresponding title, price and purchase control must be visible.
Apple's [review screenshot requirements](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)
apply to these reviewer-only images, separately from the public compositions.

The mission owner handles asset uploads, processing/order checks in App Store
Connect, product metadata and review linkage. No upload or submission is
claimed by this runbook. Original paid-purchase and Family Sharing verification
remain Franz's live checks. Rebuild and recapture affected images after a
source change; keep the source branch stable during parent inspection.
