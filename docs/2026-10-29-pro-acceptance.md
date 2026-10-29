# Pro setup acceptance checkpoint

For [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469), checked October
29, 2026. No App Store Connect changes, purchases or submissions were made.
This distinguishes completed setup from the remaining release and owner steps.

| Acceptance item | State and evidence |
| --- | --- |
| CodexBar Pro subscription group; yearly level 1 at $14.99 with seven-day trial; monthly level 1 at $1.99 | Done. October 29 GETs of subscriptions `6824195239` and `6824195141`, their USA prices and introductory offers confirm these settings. Both products are APPROVED. Group `22490183` was recorded in the [October 18 configuration receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6249425936). |
| Non-consumable lifetime at $29.99, submitted with 2.0 | Done. October 29 GET of `6824195355` confirms NON_CONSUMABLE and APPROVED. $29.99 and submission with all products/group are recorded in the [October 22 readback](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6340791288); lifetime price was not freshly re-read in this checkpoint. |
| US base; Family Sharing off; grace 16 days; multiseat default | Done per October 18/22 receipts above. Fresh October 29 reads confirm Family Sharing false for all products, both subscriptions at multiSeatStatus ENABLED, and grace optIn/sandboxOptIn true, SIXTEEN_DAYS, ALL_RENEWALS. USA subscription prices were re-read; base settings remain dated evidence. |
| en-US metadata, review screenshot per product, sandbox exclusion notes | Done per October 22 receipt. October 29 subscription localizations are en-US APPROVED; both screenshot deliveries COMPLETE; all three product review notes explicitly exclude sandbox and TestFlight original purchases. Lifetime screenshot/localization retain dated evidence. |
| APP-STORE.md Free/Pro pricing and launch sequence | Repo disclosure done in [#486](https://github.com/hemsoft-dev/codexbar-ios/pull/486). Download transition remains a Franz step under [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470). Historical $3.99 references intentionally document the paid phase; deleting them would corrupt the ledger. |
| PRIVACY.md Purchases section | Done in [policy](../PRIVACY.md#purchases); this PR makes Apple payment handling explicit. |
| SUPPORT.md Restore, original purchaser, family cutoff, offer-code route | Done in [support](../SUPPORT.md#codexbar-pro-and-restoring-purchases), with final October 31, 8 PM EDT cutoff. |
| Description links to standard EULA and privacy; promotional text | Done. [Description](../fastlane/metadata/en-US/description.txt) and [promotion](../fastlane/metadata/en-US/promotional_text.txt); submitted copy confirmed October 22. No live metadata was overwritten with current 2.0.1 preparation. |
| Product page labels widgets, multiple accounts and long history Pro | Submitted assets done per October 18/22 receipts. [Caption manifest](../release-assets/2.0.0/captions.json) labels these CodexBar Pro. The [October 21 image evidence](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6331740815) is source 30f8f208/build 6, not shipping build 5 or current main. The [live page](#live-product-page-and-privacy) still serves these labeled images. Fresh current-main captures are in [simulator evidence](#simulator-evidence); they are not shipping build 5. |
| Privacy label Data Not Collected | Done. The published US product page shows Data Not Collected on October 29 ([live check](#live-product-page-and-privacy)). The public API does not expose the questionnaire; the published label is the evidence. |
| Changelog matches shipped 2.0 | Checked [2.0.0 section](../CHANGELOG.md#200---2026-10-22) against build-5 release record. It records submission October 22; public release observed October 23. 2.0.1 remains Unreleased, including #529. Do not relabel the historical submission date as an observed release time. |
| Build number at least 5 | Done. October 29 version/build GET confirms selected VALID build 5, ID e224b2b9-c59a-44ff-bd92-d1ed7a0f6b02. Main carries later build preparation. |
| Small Business Program before shipping | Missed/unverified. [October 21 receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6326082769) inferred non-enrollment from proceeds. The [October 22 update](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6340791288) marks enrollment optional. Neither proves current enrollment or waives it on Franz's behalf. 2.0 has already shipped; enrollment now cannot satisfy the original timing criterion retroactively. |

## Remaining owner steps

The evening checks below supersede this section's earlier list; see
[Remaining for #469](#remaining-for-469). No new Pro products or submission
are needed. Free pricing, Family Sharing and post-cutoff production checks
remain Franz-owned release validation under
[#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470). No paid CI or
full UI workflow was dispatched.

## Live product page and privacy

Checked read-only on October 29, 2026 at 21:34 UTC (5:34 PM EDT) with the
public US App Store page, the iTunes lookup API and App Store Connect API GETs.

- The US page shows "Free · In-App Purchases", version 2.0.0, and lists
  Lifetime $29.99, Yearly $14.99 and Monthly $1.99. The lookup API still
  returned the cached US$3.99 price in the US, UK and Germany while Brazil and
  India returned 0. Free pricing belongs to
  [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470).
- App Privacy shows **Data Not Collected**.
- The live description and What's New text match
  [description](../fastlane/metadata/en-US/description.txt) and
  [release notes](../fastlane/metadata/en-US/release_notes.txt) exactly. The
  promotional text, name and subtitle match. The Terms of Use (standard EULA)
  and privacy-policy links in the description resolve.
- Four iPhone, four iPad and one Watch screenshot are live. The Free image is
  captioned "Free plan"; dashboard, widgets, history and Watch images are
  captioned "CodexBar Pro".
- App Store Connect: all three products APPROVED, Family Sharing off, both
  subscriptions at level 1, USA base territory, version 2.0.0
  READY_FOR_SALE with manual release.

One mismatch: the App Store Connect privacy policy URL is
`https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md`, while
[`privacy_url.txt`](../fastlane/metadata/en-US/privacy_url.txt) and the
description use `hemsoft-dev/codexbar-ios`. GitHub redirects the old path to
the current policy today, but that redirect would stop if a repository named
`HemSoft/codexbar-ios` were ever created again.

Checking the source against [PRIVACY.md](../PRIVACY.md) found two outbound
requests the policy did not describe. This PR adds both:

- Cursor renewal dates read Cursor's Stripe-hosted billing portal from
  `billing.stripe.com` and `api.stripe.com`, using temporary portal access
  returned by Cursor. The Cursor session goes only to `cursor.com`.
- The daily update check requests CodexBar's public listing from
  `itunes.apple.com` with only the App Store ID.

Neither sends data to HemSoft. The bundled privacy manifest declares no
collected data and no tracking. Both requests are made at the user's direction,
to their provider or to Apple, like the other provider requests. The label can
stay Data Not Collected.

## Simulator evidence

Captured on air on October 29 from `9e3afed` (main after #534, unchanged app
source in this PR) with Xcode 27.1 (27A9275) and task-owned iOS 26.5 and
watchOS 26.5 simulators. The capture build is a Debug simulator build of
2.0.0 (6). It is current-main evidence, not a capture of shipping build 5 and
not release qualification. No App Store purchase was made; all prices come from
synthetic fixtures or the local [StoreKit configuration](../StoreKit/CodexBarPro.storekit).

| Evidence | Method | Result |
| --- | --- | --- |
| Nine storefront scenes | `capture-storefront-assets.py` build and capture, then `compose.swift` | Passed. Fixture receipts confirm Free with one account and 7-day history, and Pro with 90-day history |
| Paywall with local StoreKit prices | `StoreKitProPreparationTests` then `StorefrontReviewCaptureTests` | Passed |
| Paywall from the free limit, yearly trial offer, Restore with no purchase | `ProCommerceJourneyTests` trial and restore journeys, `FreeTierJourneyTests` limit journey | 3 of 3 passed |
| Active trial, original purchaser | Synthetic commerce fixtures launched on the clean capture app | Rendered as expected |
| Local StoreKit purchase then Restore | `ProCommerceNativeJourneyTests/testPurchaseAndRestore` after fresh preparation | **Failed twice.** Local StoreKit showed an Apple Account sign-in prompt and the purchase stayed at "Completing your purchase…". No credentials were entered |

The purchase failure was observed on Xcode 27.1 with iOS 26.5, not the
Xcode 26.6 and iOS 26.2 toolchain on which build 5 passed this journey on
October 19. Its cause is unknown and unresolved here. It says nothing about
live purchases either way; no production purchase was tested. The production
purchase, trial and Restore checks after `T` remain under #470.

## Remaining for #469

- **Small Business Program:** Franz's decision. Either enroll as Account
  Holder or accept staying unenrolled, and record the outcome. Enrollment can no
  longer meet the original "before 2.0 ships" timing.
- **Privacy policy URL:** Franz updates the App Store Connect privacy policy
  URL to `https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md`.
  This is optional while GitHub's redirect works.

The product page and privacy label are confirmed by the live checks above.
The pull request for this section attaches current-head screenshots and
captions, which meets the screenshot validation item. Historical build-6
images are not presented as current evidence.
