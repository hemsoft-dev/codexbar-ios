# App Store Release Tracker

This document tracks the work required to ship CodexBar for iOS and iPadOS through TestFlight and App Store review.

Status last reviewed: October 21, 2026

## CodexBar 2.0 policy and preparation

The [approved Pro plan](docs/2026-10-16-codexbar-pro-plan.md) introduces a free
plan with one active account from any supported provider, the customizable
dashboard and seven days of history. CodexBar Pro adds all saved accounts,
Home Screen and Lock Screen widgets, Apple Watch and complications, up to
90 days of daily history, and usage alerts. GitHub service-status notices stay
free.

US base prices are $1.99 monthly, $14.99 yearly with a seven-day introductory
free trial for eligible customers, and $29.99 for a lifetime purchase. The app
shows Apple's localized prices and billing periods before purchase. Family
Sharing is off for all three new products. Eligible original purchasers keep
lifetime Pro after Apple verifies their purchase.

The app download moves to Free through the launch sequence below. Its existing
US$3.99 base price remains in place through the initial 2.0 rollout. A free plan
inside the app does not mean the download is already free. This repository
preparation does not upload a build, submit App Review, or change download
pricing. [Issue #469](https://github.com/hemsoft-dev/codexbar-ios/issues/469)
owns the disclosures and draft products;
[issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) owns final
qualification, submission, release and the timed price change.
Keep both issues open until their actual acceptance criteria are complete;
merged preparation code and saved draft settings do not qualify a release.

### Product configuration and review handoff

The [saved App Store Connect inventory](/tmp/codexbar-469-readiness/asc-readback-20261018T111753.999215Z.json)
was observed on October 18, 2026 at 7:17:53 AM EDT, `2026-10-18T11:17:53Z`.
It contains 40 complete collections. The independent
[post-assets audit](/tmp/codexbar-469-post-assets-audit/post-assets-audit.json)
passed 346 of 346 checks against saved evidence. These are dated draft
readbacks; the release owner must recheck current state before submission.

| Product | Identifier | Required configuration | Saved readback |
| --- | --- | --- | --- |
| CodexBar Pro Yearly | `com.hemsoft.CodexBarIOS.pro.yearly` | CodexBar Pro group, level 1, one year, USA $14.99, seven-day eligible free trial | Resource `6824195239`, `READY_TO_SUBMIT`; USA $14.99, 175 priced/available territories and 175 one-week free-trial offers |
| CodexBar Pro Monthly | `com.hemsoft.CodexBarIOS.pro.monthly` | Same group and level, one month, USA $1.99, no trial | Resource `6824195141`, `READY_TO_SUBMIT`; USA $1.99, 175 priced/available territories, zero introductory offers |
| CodexBar Pro Lifetime | `com.hemsoft.CodexBarIOS.pro.lifetime` | Non-consumable, USA $29.99, no trial | Resource `6824195355`, `READY_TO_SUBMIT`; USA $29.99 and 175 priced/available territories |

The saved subscription group is `22490183`, named CodexBar Pro. Its version
`153c92f1-497a-43d5-8902-92030fd8ef1f` is `PREPARE_FOR_SUBMISSION`.
The monthly, yearly and lifetime version records are respectively
`c8c9fb7c-663f-48c7-b3af-79bb63ba5cb3`,
`8acbb0ea-aaaf-46f4-9147-f5122af71820` and
`a29cfae6-d318-419f-9865-9a34a257f0e1`; each is also
`PREPARE_FOR_SUBMISSION`. Product readiness does not mean those versions have
been submitted or approved.

Family Sharing is off for all three products. Both subscriptions retain
Apple's default multiseat `ENABLED` setting and use ordinary full-period
payment, `UPFRONT`. The separate app-level billing grace record enables
`SIXTEEN_DAYS` for `ALL_RENEWALS` in production and sandbox. The six audited
app-download pricing and availability collections are unchanged, including
the US$3.99 download price and 175 sale territories. Preserve these settings
through the approved launch sequence.

App version `2.0.0`, ID `2c7b9bd4-b877-454d-a5a2-036b25a151f5`, is
`PREPARE_FOR_SUBMISSION` with `MANUAL` release and no phased release. Read-only verification on October 21
confirmed build 5 (`e224b2b9-c59a-44ff-bd92-d1ed7a0f6b02`) is selected and
`VALID`. It belongs to source `62f6d8e392360b91cb704c2503e9796f8ddc285c`
and retains the earlier cutoff; do not submit it under the replacement plan. Review draft `af75f0db-4b2c-403d-81e2-c3b14ab05986` is
`READY_FOR_REVIEW`, with zero items and no submitted date. The first Pro
products must accompany app version 2.0 in one website submission. Selecting
the replacement processed build and associating the products with the app version
remain pending for the replacement candidate; nothing in this draft has been submitted. The three local StoreKit
review screenshots demonstrate app UI and test-configuration prices. They do
not establish live App Store prices or production original-purchaser access.

Apple requires the first in-app purchase and first subscriptions to accompany
an app binary through the [App Store Connect website](https://appstoreconnect.apple.com).
Use **Add for Review** on the website and select the existing draft. Before
**Submit for Review**, verify that the same draft contains app version 2.0,
subscription group `22490183`, and all three monthly, yearly and lifetime
products. Add the group if it is absent; do not add a duplicate when the website
has already included it. Verify the displayed group membership rather than
inferring it from API localization behavior. Apple's
[first-submission website instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)
require these items together. The review-submission API's item-add
and submit operations do not apply to these first products; the empty API
review draft does not change that requirement. Selecting an eligible processed
build through the API remains available to the release owner after candidate
qualification. This distinction follows Apple's
[in-app purchase guidance](https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases.md)
and [subscription guidance](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review.md),
rechecked in the [saved Apple readback](/tmp/codexbar-470-first-product-submission/readback.json)
on October 18 at 8:00:53 AM EDT, `2026-10-18T12:00:53Z`.

The [October 21 scope record](docs/2026-10-21-pro-scope-decisions.md) keeps
Pro Apple-local and native Mac qualification provisional.

The [description](fastlane/metadata/en-US/description.txt),
[promotional text](fastlane/metadata/en-US/promotional_text.txt),
[release notes](fastlane/metadata/en-US/release_notes.txt) and
[review notes](fastlane/metadata/review_information/notes.txt) are prepared for
2.0. Local release copy includes the widget-readability fix and the replacement
cutoff in the 2,107-character What's New text. The draft retains build 5 copy;
saving and rereading replacement metadata remains pending approval. Other
metadata values are unchanged. Do not copy the
2.0 metadata onto the live 1.4.0 listing. The description includes Apple's
[standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
and the public [privacy policy](https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md).
The existing GitHub privacy and support URLs remain the release destinations.

The [build 6 preparation record](docs/2026-10-23-build6-release-preparation.md)
maps the final local copy to the 2.0 changelog and records the immutable-candidate
handoff. Qualification, archive/export and final approval are still pending.

### Cutover and original-purchaser rules

The replacement release is `2.0.0 (6)`; all 14 project configurations use
that version and build. Qualification of this replacement immutable candidate is pending.
The preparation targets October 23, 2026 submission as approved by Franz on October 21; he must
approve submission separately. If that date moves, recompute the cutoff before
qualifying another candidate.
The [2.0 changelog](CHANGELOG.md#200---unreleased) remains Unreleased until
the release date is established. October 23 is the planned submission date,
not an observed release date. Update the heading and all inbound anchors
together when the release date is known. The [privacy policy](PRIVACY.md) is effective
October 18; that date does not record App Store submission or distribution.
The compiled cutoff `T` remains **PROVISIONAL: November 5, 2026 at 7:00 PM EST**,
which is `2026-11-06T00:00:00Z`. It is fourteen calendar days after the planned
submission date `2026-10-23 UTC`, not evidence of a completed submission.
The value in
[ProOriginalPurchaserPolicy](CodexBarIOS/Services/ProOriginalPurchaserPolicy.swift)
is updated by this preparation. Before submission,
[issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) must
recompute and finalize `T` from the actual planned submission date, then verify
that the compiled value, original-purchaser notice, support page, promotional
text, release notes and review notes name the same instant. A later deadline
requires updated copy and a newly qualified candidate.

Original-purchaser access requires verified, non-revoked production
`AppTransaction` evidence. The evaluator accepts a finite original purchase
date strictly before `T`, or a recognized paid version. For the version rule,
a plain ASCII integer is a build number and qualifies at 4 or below. It is
never retried as a marketing version, including on integer overflow. Otherwise,
only a dotted numeric marketing version below 2.0 qualifies. Malformed versions
fail the version rule but do not invalidate an independently qualifying date.
Sandbox, TestFlight and Xcode AppTransactions never qualify as original
purchases. Fresh verified evidence must also pass the resolver's saved
revocation ordering; stale evidence cannot undo a recorded revocation.

Family members of original purchasers must install before November 5, 2026 at
7:00 PM EST, `2026-11-06T00:00:00Z`, under the current provisional candidate.
The [support page](SUPPORT.md#codexbar-pro-and-restoring-purchases) explains the
one-time free lifetime offer-code route for missed cases. No codes are created
or distributed by this disclosure work. Franz's original-purchase and family
device checks remain pending; local StoreKit tests do not prove either result.
Those production checks belong to Franz and are not prerequisites for
agent-owned implementation or automated delivery.

### Approved launch sequence

1. Before submission, set `T` to 00:00 UTC fourteen calendar days after the
   planned submission date. Confirm that the 1.4.0 review is finished. Require
   version 2.0.0 and build 5 or higher across the app and embedded products,
   then verify the built archive rather than relying only on project text.
   Recheck the cutoff disclosures, the privacy policy's effective date and
   the [2.0 changelog](CHANGELOG.md#200---unreleased) against the final candidate.
2. Submit 2.0 and all first Pro products together through the
   [App Store Connect website](https://appstoreconnect.apple.com).
   Verify the subscription group and all three products are in the same draft
   as the app version before submitting.
   Use manual release with phased release off. Keep the existing US$3.99 app
   price and sale territories.
   Require the exact candidate's five quality jobs and complete iPhone/iPad
   release UI gate before upload or release.
3. Release manually only while at least six full days remain before `T`.
   Wait 48 hours after release and verify that several storefronts serve 2.0.
   Do not make the download free while a storefront still serves 1.4.0.
4. Schedule Free about 72 hours before `T`, accounting for the latest
   storefront start time. Verify Free in every storefront before `T`.
   Paid and free downloads before `T` deliberately receive lifetime Pro through
   the date rule. Record requested and actual effective times separately.
5. After `T`, new free downloads use the free plan. Verify the production free
   download, Pro screen, eligible trial and Restore. Franz verifies original
   1.x lifetime access and family-device behavior. Never raise the app price
   again after `T`.

If approval leaves fewer than six days before `T`, do not release. Reject the
approved build while it is Pending Developer Release and submit a replacement
2.0 build with a later `T` and fresh qualification. Do not attempt to create
2.0.1 before 2.0 has been distributed.

If 2.0 is already distributed and paid distribution cannot end safely before
`T`, remove it from sale at least 48 hours before `T`. Verify removal in several
storefronts and keep it off sale until a 2.0.1 with a later cutoff is live.
After the Free transition, existing grants stay granted. Do not raise the
price or extend `T` to restore paid sales; that would also grant lifetime Pro
to intervening free downloads. If acquisition must stop, remove the app from
sale. These are the [approved rollback rules](docs/2026-10-16-codexbar-pro-plan.md#rollback).

| Checkpoint | Requested action and time | Actual App Store Connect time | Storefront observations | Source SHA / build / T | Pending Franz checks |
| --- | --- | --- | --- | --- | --- |
| Final candidate and cutoff | Recheck actual submission date against planned October 23 UTC | Not submitted by this preparation | Not applicable | Candidate SHA pending; planned 2.0.0 build 6; provisional T above | None for repository preparation |
| Exact-candidate qualification | Before upload/release | Pending #470 | Not applicable | Record qualified SHA and built versions | Live provider comparisons remain separate |
| Manual submission | Website submission of app 2.0 plus all first products; paid price; no phased release | Pending #470 | Existing price retained until launch sequence | Record selected build and finalized T | Small Business enrollment before shipping |
| Manual release | At least six days before T | Pending approval and #470 | Record release visibility | Same qualified candidate | None for draft setup |
| Propagation | Wait full 48 hours after release | Pending release | Record checked storefronts and observed 2.0 versions | Record source/build/T | None |
| Free schedule | About 72 hours before T; include latest region start | Pending #470 | Verify every storefront Free before T | Record source/build/T and schedule | None |
| Post-cutoff | After T | Pending launch | Production download, Pro, trial and Restore | Record source/build/T | Original 1.x purchase and family device |

The release ledger stays open through the price transition and post-cutoff
checks. The following release actions have not been completed:

- [ ] Freeze the merged candidate SHA and recheck the submission date, cutoff,
  finalized release copy and built `2.0.0 (6)` versions.
- [ ] Pass the exact candidate's complete manual release gate on Xcode
  26.6 / 17F113, including native commerce, both UI families and function risk.
- [ ] Archive, export, upload and verify processing, then select that exact build.
- [ ] Associate all first Pro products with app version 2.0 and submit once
  through the [App Store Connect website](https://appstoreconnect.apple.com).
- [ ] Record approval and manually release with at least six full days before T.
- [ ] Wait 48 hours and record storefront observations serving 2.0.
- [ ] Schedule Free, record requested and actual regional times, and verify
  every storefront is Free before T.
- [ ] Record post-cutoff production checks and Franz's original-purchase and
  Family Sharing results without treating pending checks as passes.

### Build 5 qualification and replacement boundary

Build 5 was qualified on air at source
`62f6d8e392360b91cb704c2503e9796f8ddc285c` on October 19. The local native
StoreKit matrix, iOS function risk, paired performance experiment and both full
UI families passed. Native/UI qualification used Xcode 26.6 with iOS 26.2;
the performance receipt records Xcode 27.1. These are separate observations.
The retained local evidence is `/tmp/codexbar-470-qual-62f6d8e`.
The earlier monthly-finish failures are historical diagnostics superseded by
that pinned native run, not open failures of build 5.

[Hosted CI](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39315798936)
passed SwiftLint, strict concurrency, watchOS tests/risk and smoke. Its iOS
ordinary tests passed, but native commerce passed 24 of 25 and the complete
hosted UI gate failed without running its journeys. The local exact-source
native/UI passes are recorded separately; the hosted gate is not green.
[Hosted security](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39315802645)
passed. Hosted performance was inconclusive; the local paired experiment passed.
None of these receipts qualifies changed source or replacement build 6.

The build 5 archive and export passed signature, provisioning, bundle-version,
privacy-manifest and export-compliance verification. The IPA SHA-256 is
`819b38cc6bb45f1ea6bd90bc1f34af3a70b39eedb4fe3cd248692f69ea0293ec`.
It was uploaded October 19 at 7:12 PM EDT, processed as `VALID`, and selected
on the draft. The read-only October 21 check confirms the app remains
`PREPARE_FOR_SUBMISSION`, manual release, phased release absent, and the review
submission has no submitted date. Upload and TestFlight availability are not
App Review submission or customer release.

The original October 18 planned submission date has passed. Build 6 moves the
provisional cutoff to November 5 at 7 PM EST, November 6 at midnight UTC,
for a planned October 23 submission. All replacement qualification, archive,
upload and selection remain pending. Current task authority is **Prepare**:
Franz must approve App Store submission, release, pricing, availability,
customer publication or spending at the final concrete step. Do not inherit
submission authority from the earlier mission ledger.

### Native marketing and review assets

The [2.0 asset runbook](release-assets/2.0.0/README.md) describes the current
capture procedure. The checked-in sources are the
[caption manifest](release-assets/2.0.0/captions.json),
[capture command](scripts/capture-storefront-assets.py) and
[native Swift/AppKit compositor](scripts/storefront-assets/compose.swift).
The public set contains four iPhone scenes, four iPad scenes and one native
Watch overview. A separate `CodexBarStorefrontAssets` scheme selects only
`StorefrontReviewCaptureTests/testCaptureThreeLocalStoreKitProducts` for the
three product-review captures.

Capture only after the source commit is final. Generated assets and provenance
are kept outside the checkout under
`/tmp/codexbar-469-validation/artifacts/release-assets/2.0.0`, with separate raw,
public and review images. This avoids an asset-only commit changing the source
identity. The release owner retains the uploaded files and checks their
indexed hashes before any replacement.
The saved post-assets audit records all nine public placements as `ACTIVE`
and all three product-review screenshots as `COMPLETE`. All 12 Apple-processed
images independently decode to the same RGBA8 pixels and dimensions as their
source PNGs; processed PNG bytes differ. Preserve the existing artifact index,
source/app hashes and upload receipts. The audit verifies saved processing
and pixel preservation; it does not claim a new composition review or release
qualification. The separate marketing capture method is excluded from the
51 release user journeys per device family.

Pro scenes must enable Pro with synthetic provider data. The Free scene must
use one active account and seven-day history. Every public image showing
multiple active accounts, widgets, longer history or Watch contains a visible
CodexBar Pro label in the image, outside the app controls. Fit the complete
native viewport proportionally without cropping. Public iPhone images are
1320×2868 and iPad images are 2064×2752, opaque RGB; Watch stays at its accepted
native size. The three uncomposed review screenshots show the respective
monthly, yearly and lifetime product with actual localized values from the
local StoreKit test configuration. Preserve source/app hashes, signing and
fixture-isolation evidence separately from live App Store configuration.

### Copy and privacy release checks

Use the family-deadline promotional text before `T`. After `T`, and only after
worldwide Free is verified, replace it with this evergreen text:

```text
Start free with one AI account and 7-day history. CodexBar Pro adds all accounts, widgets, Watch, alerts and 90-day history. Original purchasers keep lifetime Pro.
```

Remove the expired family-install request from What's New at the same
transition. Keep the historical deadline and offer-code help in support copy.
Revalidate Apple's metadata limits after every timestamp change.

Privacy remains **Data Not Collected** for this local-only implementation.
The app-owned purchase cache contains access, verification and timing state,
including unresolved verification and denials; it excludes Apple Account and
transaction identifiers and payment details. Provider snapshots still contain
local account identifiers, labels and usage. Apple's
[privacy guidance](https://developer.apple.com/app-store/app-privacy-details/)
distinguishes on-device processing and Apple's own collection from developer
collection. Record the actual privacy-label readback separately; the source
review alone is not proof of saved App Store Connect answers.

The release owner's separate [app-information audit](/tmp/codexbar-470-app-info/audit.json)
passed 17 checks over seven complete read-only collections observed on
October 18 at 7:45:40 AM EDT, `2026-10-18T11:45:40Z`. Distributed and editable
app information agrees on Developer Tools / Utilities, the base 4+ rating,
en-US name and subtitle, and the saved
[privacy URL](https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md).
These fields do not verify the unpublished privacy questionnaire, legal
agreements or Small Business Program status.

Paid Apps Agreement status and Small Business Program membership remain
**UNVERIFIED**. Enrollment remains pending for Franz, who must complete
[Small Business Program enrollment](https://developer.apple.com/app-store/small-business-program/)
before 2.0 ships. Do not infer enrollment or current agreement status from
historical sales. These pending owner checks do not prevent preparation of
repository copy, native assets or unsubmitted product drafts.

## Published 1.x history and earlier preparation

- Version `1.3 (3)` was the distributed release at the final submission check.
- Version `1.4.0 (4)` was submitted for App Review on October 7, 2026 at 4:56 PM EDT under
  [release issue #373](https://github.com/hemsoft-dev/codexbar-ios/issues/373).
  Apple approved it, and it has been live on the App Store since October 8, 2026 at
  15:14 UTC. Apple's public lookup (`https://itunes.apple.com/lookup?id=6787769891`)
  reports version `1.4.0` with `currentVersionReleaseDate` `2026-10-08T15:14:44Z`,
  checked on October 16, 2026 ([#471](https://github.com/hemsoft-dev/codexbar-ios/issues/471)).
- Shipping source is immutable commit `54b2a489cadf38af0c741a3553249e9411fca0be`, tagged
  [`v1.4.0`](https://github.com/hemsoft-dev/codexbar-ios/tree/v1.4.0). The frozen
  `release/1.4.0-rc-54b2a48` branch was deleted on October 16, 2026 after the tag replaced it. [PR #415](https://github.com/hemsoft-dev/codexbar-ios/pull/415)
  merged the dated, consolidated 1.4.0 changelog before this archive was built.
  The next `1.5.0 - Unreleased` section started after that release cut; it was renamed
  `2.0.0 - Unreleased` on October 16, 2026 ([#460](https://github.com/hemsoft-dev/codexbar-ios/issues/460)).
- All seven local gates passed with 711 iOS and 61 Watch tests. All five required
  CI jobs and the complete 28-test iPhone and iPad UI suites passed for the shipping
  SHA in [run 37661183114](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37661183114).
  Initial iPad attempt 1 failed one Greptile account-navigation assertion; its native
  bundle, video and logs remain preserved. One complete unchanged-source focused
  journey passed on matching iOS 26.5, then the bounded failed-jobs attempt 2 passed.
  The retry preserves the original failure and does not claim an app fix.
- The exported iPhone app, iOS widget, Watch companion and Watch complication all
  report `1.4.0 (4)`. Distribution signatures, App Store provisioning, privacy
  manifests and export-compliance declarations passed for every submitted product.
  Two automatic export attempts failed and remain recorded. One new distribution
  certificate and four matching App Store profiles enabled a successful manual
  export of the same archive, without role changes or certificate revocation.
  IPA SHA256 is `248e61c112785ff72a8641df9eb873743bb7646c2989c932018c6c6ff7b54910`.
- Apple's upload delivery ID is `53f759b4-3521-4fdb-8bb2-c8ad2d0bdfa5`, processed build ID
  `53f759b4-3521-4fdb-8bb2-c8ad2d0bdfa5`, version ID `8f1f19dc-ec43-420f-b336-fb20271d6d3c`, and review submission ID
  `ab271b71-a450-4325-a6d5-2a90593b4b06`. Binary processing completed as `VALID` before selection.
- Saved en-US metadata and review notes match the prepared copy. New storefront
  previews contain nine iPhone, nine iPad and two Apple Watch screenshots. Privacy
  remains Data Not Collected, age 4+, and the support/privacy URLs and opaque
  1024-pixel app icon were verified. Legacy demo credentials were cleared.
- Version 1.4.0 shipped at US$3.99 in 175 available territories, with automatic
  release after approval, immediate rollout and the existing star rating. That
  release preserved Mac, Vision Pro, public distribution and education-discount
  settings. This is the historical 1.4.0 policy, not the 2.0 launch policy.
- TestFlight and a fresh final-candidate Release install/launch on the physical
  iPhone were skipped. The earlier development launch passed. The shipping source
  differs from that device-tested candidate only in documentation; production and
  test inputs are unchanged. Live provider comparisons remain Franz-owned and pending.
  Runtime warnings remain unresolved. Original hosted performance failure is
  preserved alongside the complete local passing comparison under unchanged policy;
  security/performance provenance is explicit source equivalence, not fresh analysis.
- [#405](https://github.com/hemsoft-dev/codexbar-ios/issues/405) and
  [#409](https://github.com/hemsoft-dev/codexbar-ios/issues/409) were deferred to V1.5.
  #405 has since been completed. #409 moved to V2.0 when the next release became 2.0.0
  ([#460](https://github.com/hemsoft-dev/codexbar-ios/issues/460)) and is still blocked on Greptile.
  The release and review copy disclose the Greptile Google-backed billing sign-in
  limitation. The complete local artifact ledger is
  `DerivedData/ReleasePreparation/1.4.0-54b2a48/release-status.md`, with Apple write
  and readback receipts in `DerivedData/ReleaseSubmission/1.4.0-build4-20261007`.
- App builds, installs, and launches on the connected development iPhone.
- Main dashboard, provider settings, widget support, and snapshot trend improvements are on `main`.
- The embedded Apple Watch companion shows presentation-only snapshots
  synchronized from iPhone. It does not fetch provider data or receive
  credentials; system scheduling controls background refresh.
- Development signing is stable through the dedicated CodexBar keychain documented in `AGENTS.md`.
- Apple Developer Program membership is confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- App Store Connect app record is created as `CodexBar Usage Monitor` with app ID `6787769891`.
- The expanded Issue #22 six-scene screenshot set was regenerated, reviewed
  at full size, and synced to the App Store Connect version 1.1 submission for
  iPhone and iPad on 2026-07-11 using safe demo data.
- Product metadata, support URL, privacy policy URL, copyright, and App Review notes have been added in App Store Connect.
- TestFlight install has been confirmed by the user on iPhone and iPad.
- App Store Connect app information is set to primary category `Developer Tools`, secondary category `Utilities`, and age rating `4+`.
- The updated social-media age-rating questions are complete for CodexBar, with
  both social-media capabilities set to `No`; the calculated rating remains
  `4+`.
- Release archive `1.1 (1)` was uploaded to App Store Connect on 2026-07-15,
  finished processing, and was selected for the version 1.1 submission.
- Version 1.1 build `1.1 (1)` is publicly available. Apple's public listing
  reports a release date of 2026-07-16, re-verified on 2026-07-28. The
  repository's 1.1.0 changelog snapshot remains dated 2026-07-15.
- Version 1.2 release preparation is tracked by Issue #239. The marketing
  version is `1.2`, the release build number is `2`, and privacy-safe iPhone,
  iPad, and Apple Watch storefront captures are prepared in
  `release-assets/1.2`.
- Version 1.3 build `1.3 (3)` is publicly available. Apple's public lookup
  response reports a release time of August 24, 2026 at 1:21:45 PM EDT,
  re-verified on August 25. The repository's 1.3.0 changelog snapshot remains
  dated August 23. Local `fastlane/metadata/en-US/release_notes.txt` now contains
  proposed 1.4.0 copy, not the distributed 1.3 text.

## Apple Requirements To Keep Current

- App uploads must be built with Xcode 26 or later and the iOS/iPadOS 26 SDK
  or later as of 2026-04-28. Since 2026-09-09, uploaded iOS/iPadOS apps must
  target iOS 13 or later. Rechecked against
  [Apple's requirements](https://developer.apple.com/news/upcoming-requirements/)
  on 2026-10-06; CodexBar targets iOS 17.
- App privacy answers in App Store Connect must accurately describe CodexBar's data handling and any third-party SDK behavior.
- iOS App Store listings require a privacy policy URL.
- If review cannot exercise paid or account-specific provider features directly, provide clear App Review notes and a short demo video.
- Sign in with Apple is not expected to be required unless CodexBar adds its own account system or offers a general third-party/social login option for a CodexBar account. Provider-specific auth for accessing the user's existing provider data should be explained in review notes.

Reference links:

- [Apple upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Submitting apps to the App Store](https://developer.apple.com/app-store/submitting/)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Review preparation](https://developer.apple.com/distribute/app-review/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Earlier release work and recurring checks

Checked items below record the named 1.x release history; unchecked items remain manual or App Store Connect work for a future
submission unless a version-specific note says otherwise.

### 1. App Store Connect Setup

- [x] Confirm Apple Developer Program membership and team ownership. Membership confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- [x] Create the App Store Connect app record. Created as `CodexBar Usage Monitor`, app ID `6787769891`, on 2026-07-05.
- [x] Confirm bundle ID, SKU, primary language, category, and age rating. App Store Connect uses bundle ID `com.hemsoft.CodexBarIOS`, SKU `codexbar-ios`, primary language `English (U.S.)`, primary category `Developer Tools`, secondary category `Utilities`, and age rating `4+`.
- [x] Decide initial availability: iPhone and iPad.
- [x] Revisit the 1.x pricing policy for 2.0. The free/Pro policy and timed
  transition are documented above; the actual price change remains pending
  [issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470).

### 2. Production Signing And Upload

- [x] Confirm the project has App Store distribution signing available for the app and widget extension.
- [x] Archive a release build from Xcode or `xcodebuild`. Release archive
  created for version `1.1` build `1` on 2026-07-15; version `1.0` build `1`
  was the earlier initial-release archive.
- [x] Validate the archive.
- [x] Upload the build to App Store Connect. Build `1.1 (1)` uploaded
  successfully on 2026-07-15.
- [x] Confirm TestFlight processing completes for both app and widget
  extension. App Store Connect finished processing build `1.1 (1)`.

### 3. Product Page Assets

- [x] Finalize app name and subtitle. App name is `CodexBar Usage Monitor`; subtitle is `AI usage, limits, and balances`.
- [x] Prepare promotional text in `fastlane/metadata/en-US/promotional_text.txt`.
- [x] Prepare the full app description in `fastlane/metadata/en-US/description.txt`.
- [x] Prepare keywords in `fastlane/metadata/en-US/keywords.txt`.
- [x] Sync the Issue #22 promotional text, description, and keywords to App
  Store Connect and verify their previews. The version 1.1 submission was
  updated and verified on 2026-07-11.
- [x] Provide support URL and add it to App Store Connect. Public support page is `https://github.com/hemsoft-dev/codexbar-ios/blob/main/SUPPORT.md`.
- [ ] Provide marketing URL if desired.
- [x] Provide privacy policy URL and add it to App Store Connect. Public privacy policy is `https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md`.
- [x] Prepare screenshots for required iPhone sizes. Six deterministic iPhone 17 Pro Max images at `1320x2868` were generated and reviewed at full size on 2026-07-11.
- [x] Prepare screenshots for required iPad sizes. Six deterministic iPad Pro 13-inch (M5) images at `2064x2752` were generated and reviewed at full size on 2026-07-11.
- [x] Upload the Issue #22 iPhone and iPad screenshot sets to App Store Connect
  and verify their order and cropping. Both device sets contained six ordered
  screenshots in the version 1.1 submission on 2026-07-11.
- [x] Prepare Apple Watch screenshots for the watch-enabled version 1.2
  submission. Two deterministic dashboard scenes use only fictional account
  labels and values and are flattened without alpha at an Apple-accepted native
  Watch size. App Store Connect upload and preview verification remain part of
  the final submission step.
- [ ] Consider an app preview video for a future release.
- [ ] Verify the App Store icon renders correctly and has no transparency
  before the next release submission.

### Product Claim Matrix

| Product-page claim | Verified source or constraint | App Store wording guidance |
| --- | --- | --- |
| Tracks ChatGPT / Codex, GitHub Copilot, GitHub Billing, Claude, Grok, X Subscription, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot (Kimi), Greptile, and Google Gemini | Current provider list used by the app; metrics vary by account and service | Name exactly these providers; do not imply official affiliation or complete metric availability. |
| Shows usage, limits, balances, reset timing, refresh state, alerts, and history | Provider data varies by API/account type | Say metrics appear where each provider makes them available. |
| Supports multiple accounts and provider groups with CodexBar Pro | Free refreshes one active account; Pro refreshes all saved accounts | Label multiple active accounts as CodexBar Pro; do not imply team administration. |
| Offers Home Screen and Lock Screen widgets with CodexBar Pro | Widget extension and entitlement checks | Label widgets as CodexBar Pro; iOS controls refresh timing. |
| Offers Apple Watch, complications and up to 90-day history with CodexBar Pro | Shared access checks; free history is limited to seven days | Put a visible CodexBar Pro label inside every public image showing these benefits. |
| Stores credentials locally and uses Keychain where appropriate | Privacy policy and app behavior | Say credentials stay on device and are stored in Keychain where appropriate. |
| Makes provider requests directly from the device | Current network architecture | Say no CodexBar account and no HemSoft backend for provider credentials or usage data. |
| Independent provider dashboard | Legal/brand constraint | Include a clear non-affiliation disclaimer wherever provider names are used prominently. |

### Product Narrative

CodexBar is a local companion dashboard for people who use several AI coding
and assistant services. The App Store page should emphasize quick status
checking before work: what account is close to a limit, which balance changed,
what refreshed recently, and which widgets keep the most important providers
visible. Keep the tone practical and privacy-forward. Avoid claims about
provider completeness, guaranteed metric availability, automatic background
accuracy, official partnerships, or server-side syncing.

### Historical 1.4.0 screenshot workflow

The commands and nine-scene order below document the 1.4.0 captures. For 2.0,
use the [2.0 runbook](release-assets/2.0.0/README.md) and the external artifact
path recorded above, with separate build output outside the repository.
Every public image implying several active accounts, widgets, long history or
Watch must contain a visible CodexBar Pro label outside the app controls. The
Free scene must actually use one active account and seven-day history. Fit the
entire native app viewport proportionally, with no crop or stretch, into an
opaque RGB PNG at the exact sizes below. Capture from the final committed
source; preserve hashes, fixture state, source/build and native provenance.
Do not overwrite published 1.x assets.

Historical capture command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/capture-app-store-screenshots.sh
```

The app contract for each launch is:

```text
--app-store-screenshots --app-store-scene <scene> --app-store-appearance <light|dark> --app-store-settle-seconds <seconds>
```

The capture script defaults the scene-settling window to two seconds. Override
it with `SCREENSHOT_SETTLE_SECONDS` when a slower simulator or CI runner needs
more render time; the app clamps the supplied value to the `0...30` second
range before signaling readiness.

Readiness is complete only when this command returns the requested scene:

```sh
cat "$(xcrun simctl get_app_container <device-udid> com.hemsoft.CodexBarIOS data)/Library/Caches/app-store-screenshot-ready"
```

The script polls a marker in the app's simulator data container, with a timeout, instead of
using a fixed delay. It deletes stale generated PNGs from both
`AppStore/Screenshots` and `fastlane/screenshots/en-US`, builds once for the
simulator, then performs a clean uninstall/install per device and a fresh
launch for each scene. Simulator selection filters the requested runtime and
active SDK, and the build uses that same selected phone UDID. Failed raw
captures remain in a unique temporary directory outside storefront output.
Status bars are forced to `9:41` with full battery before capture.

Scene order:

1. `dashboard-overview` in light appearance
2. `dashboard-dark` in dark appearance
3. `gemini` in light appearance
4. `grok` in dark appearance
5. `github-billing` in light appearance
6. `widget-builder` in light appearance
7. `accounts` in dark appearance
8. `provider-copilot` in light appearance
9. `history` in dark appearance

The three new scenes put the selected synthetic account first in the actual
Dashboard. They do not call live provider services or change customer setup.
Use `OUTPUT_DIR`, `FASTLANE_OUTPUT_DIR`, and `DERIVED_DATA` to keep generated
files isolated. Watch capture defaults to `release-assets/1.4.0/screenshots`
and accepts `OUTPUT_DIR` and `DERIVED_DATA` overrides; it never needs to modify
published 1.2 assets.

Required output sizes:

| Family | Simulator | Pixel size |
| --- | --- | --- |
| iPhone | iPhone 17 Pro Max | `1320x2868` |
| iPad | iPad Pro 13-inch (M5) | `2064x2752` |

Primary generated filenames include family, order, scene, and appearance, for
example `iphone_01_dashboard-overview_light.png` and
`ipad_01_dashboard-overview_light.png`. The final ordered Fastlane
copies use stable numbered names in `fastlane/screenshots/en-US`, with iPhone
and iPad files sharing the same scene number.

### Full-Size Visual QA

Local QA completed on 2026-07-11 for all 12 generated images. Repeat this
review after any regeneration:

After regeneration, review the full-size PNGs before syncing:

- Confirm every screenshot matches the expected dimensions above.
- Open each image at full size, not only as Finder thumbnails.
- Confirm status bar time is `9:41`, battery is full, and no simulator chrome
  or debug overlays are visible.
- Confirm light/dark appearance matches the scene plan.
- Confirm provider/account demo data is safe, plausible, and not personally
  identifying.
- Confirm no text is clipped, overlapped, truncated awkwardly, or hidden behind
  the Dynamic Island, home indicator, or iPad safe areas.
- Confirm widgets, history, accounts, provider details, and dashboard images
  match the marketing claims in the description.

### App Store Connect Sync And Preview

Issue #22 metadata and screenshots were generated, locally verified, and synced
to the App Store Connect version 1.1 submission on 2026-07-11:

1. [x] Regenerate screenshots with the command above.
2. [x] Run local validation for shell syntax, metadata limits, PNG dimensions,
   and full-size visual quality.
3. [x] Sync `fastlane/metadata/en-US` and `fastlane/screenshots/en-US` to App Store
   Connect. The metadata and twelve screenshots were added to the version 1.1
   submission in Safari on 2026-07-11.
4. [x] Preview the iPhone and iPad product pages in App Store Connect.
5. [x] Verify the subtitle, promotional text, description, keywords, and ordered
   screenshots render correctly in the preview.
6. [x] Record the sync date and any App Store Connect adjustments here before final
   submission. The two inherited 1.0 screenshots per device class were replaced
   with the six-scene 1.1 sets. Files were uploaded individually to preserve the
   intended numbered order after App Store Connect shuffled an initial batch
   upload. The prepared subtitle required no adjustment, and 1.1 release notes
   were added from `fastlane/metadata/en-US/release_notes.txt`.

### 4. Privacy And Data Handling Follow-Up

- [ ] Re-audit all network calls made by provider fetchers before the next
  release.
- [x] Confirm credentials are stored locally in Keychain and are not sent to HemSoft servers.
- [x] Confirm widget data is stored only in the app group container.
- [x] Confirm analytics/crash reporting status. No analytics, advertising, or crash-reporting SDKs are present in the current release.
- [x] Draft privacy policy covering local credentials, third-party provider API calls, billing/usage data, and data retention.
- [ ] Re-audit App Store Connect privacy nutrition labels before the next
  submission.
- [ ] Re-audit third-party packages and SDKs for privacy manifests or signature
  requirements before the next submission.

### 5. Brand And Legal Follow-Up

- [ ] Re-audit provider logos and names used in the app and widgets before the
  next release.
- [ ] Re-confirm logo usage under each provider's current brand guidelines.
- [ ] Replace any newly identified risky brand asset with a permitted mark or
  neutral in-app icon.
- [ ] Re-check non-affiliation disclaimers before the next submission.
- [ ] Re-confirm provider-name wording (Codex, Copilot, GitHub Billing, Claude,
  Grok, X Subscription, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot (Kimi), Greptile,
  Google Gemini) before the next submission.

The completed content-rights declaration in Final Submission records the 1.1
submission. These unchecked items are a broader future-release brand audit.

### 6. App Review Readiness For A Future Release

- [x] Write App Review notes explaining that CodexBar is a local companion dashboard for user-owned provider accounts.
- [x] Explain that provider credentials remain on device in Keychain.
- [x] Explain which features require user-owned third-party accounts and API keys.
- [ ] Provide a reviewer path for seeing the dashboard without real paid
  accounts in a future submission, if possible.
- [ ] If no demo mode is appropriate, provide a concise demo video for a future
  submission showing configured providers, widgets, and refresh behavior.
- [ ] Re-verify all error states before the next submission.
- [ ] Re-verify settings can add, edit, refresh, and remove each provider before
  the next submission.
- [x] Provide a persistent Settings Feedback & Support destination for writing
  an App Store review and opening structured public support channels.
- [x] Review diagnostic reporting against App Store privacy answers: reports
  are user-initiated public GitHub transfers previewed on device, use only a
  typed allowlist, and add no analytics, crash reporting, background upload,
  protected-resource access, backend collection, or new privacy-manifest API.
- [x] Gate native rating requests behind sustained successful use, with no
  first-launch, onboarding, automatic-refresh, incentive, or sentiment gate.

### 7. TestFlight History And Future Verification

- [x] Upload the first TestFlight build. Build `1.0 (1)` uploaded successfully from Xcode on 2026-07-05 and later reported `VALID` by App Store Connect.
- [x] Install from TestFlight on iPhone.
- [x] Install from TestFlight on iPad.
- [ ] Re-verify widgets in TestFlight before the next release.
- [ ] Re-verify provider credentials survive app restarts before the next
  release.
- [ ] Re-verify background/widget refresh behavior before the next release.
- [ ] Re-verify accessibility basics before the next release: Dynamic Type,
  VoiceOver labels, contrast, and tappable target sizes.
- [ ] Review TestFlight crash logs and fix any launch, widget, or auth issues
  before the next release.

Review-request test note: development-signed builds expose **Test Rating
Prompt** in Settings and StoreKit displays the native request for UI testing.
The native request has no effect in TestFlight, so TestFlight verification must
use the persistent **Rate CodexBar** link instead.

### 8. Final Submission

Manual CI release gate for every future version:

- [ ] After all intended release changes have merged, create or select the
  release-candidate branch or tag and record its resolved SHA.
- [ ] Dispatch the `CI` workflow manually against that candidate. Confirm its
  `headSha` matches and all five quality jobs plus `Full iOS UI validation`
  pass before uploading or releasing the build.
- [ ] If the candidate SHA changes, discard the earlier result and pass a new
  manual run. Routine pull requests do not require this gate.

Version 1.4.0 submission status:

- [x] Consolidate and date the customer changelog before archiving, preserve published
  history, and derive the exact What's New copy from shipped changes.
- [x] Freeze and qualify the exact merged source SHA, including seven local gates,
  five required CI jobs, fresh function-risk reports and complete native UI suites.
- [x] Archive and export all four products as 1.4.0 build 4; verify distribution signing,
  provisioning, privacy manifests and export-compliance declarations.
- [x] Upload the verified IPA once and wait for binary processing to become `VALID`.
- [x] Select the exact processed build and verify saved en-US metadata, review notes,
  contact details, privacy, age rating, icon, URLs and every maintained screenshot family.
- [x] Preserve pricing, availability, release policy, rollout and the existing rating.
- [x] Submit once for App Review and verify Apple's version/submission state.
- [x] Record accepted TestFlight/physical-device omissions, unresolved runtime warnings,
  original failures and source-equivalent security/performance evidence honestly.
- [x] Start the next 1.5.0 Unreleased changelog section through the reviewed PR path.
- [x] Confirm App Review approval and public distribution when Apple completes review.
  Live since 2026-10-08 15:14 UTC per Apple's public lookup; recorded in
  [#471](https://github.com/hemsoft-dev/codexbar-ios/issues/471).

Version 1.3 submission status:

- [x] Prepare version 1.3 "What's New" copy from the dated 1.3.0 changelog.
- [x] Set the repository release candidate to version `1.3 (3)` across every
  Xcode target configuration.
- [x] Run the canonical SwiftLint gate and the complete Perfection audit on the
  release candidate. SwiftLint reported zero violations in 91 files, and all
  five supported build and test gates passed on 2026-08-23.
- [x] Create a signed Release archive and perform a local `app-store-connect`
  export without uploading. The iOS app, iOS widget, Apple Watch app, and Watch
  widget all export as `1.3 (3)` with App Store provisioning, valid distribution
  signatures, privacy manifests, and export-compliance declarations.
- [x] Recheck repository metadata needed by the submission. The support and
  privacy URLs return successfully, the App Store icon is an opaque 1024-pixel
  square, release notes fit Apple's limit, and the pinned package graph contains
  no third-party runtime SDK.
- [x] Upload and validate build `1.3 (3)` in App Store Connect. Apple completed
  processing on 2026-08-23 with binary state `Validated`, symbols included, no
  non-exempt encryption, and build upload ID
  `3addfe4f-f3fe-4cfb-a2b5-60fe57da5219`.
- [ ] Complete TestFlight verification on iPhone, iPad, and Apple Watch.
- [x] Reconfirm App Store Connect privacy answers, review notes, age rating,
  app icon, support and privacy URLs, pricing, and availability for version 1.3.
  The listing reports Data Not Collected, age 4+, a $3.99 US price, and
  availability in 175 regions.
- [x] Preview the reused storefront screenshots, select build `1.3 (3)`, and
  submit the release for App Review. Version 1.3 reused six iPhone, six iPad,
  and two Apple Watch screenshots. Apple approved submission
  `ba051fea-b0bc-4c47-9e08-3ed9c69bd9a6`, and the automatic release became
  publicly available on 2026-08-24 at 17:21:45 UTC with immediate rollout and
  the existing star rating.

Version 1.2 submission preparation history:

Version 1.2 submission status:

- [x] Prepare version 1.2 release copy and privacy-safe iPhone, iPad, and Apple
  Watch screenshots.
- [x] Set the repository release version to `1.2 (2)` and date the 1.2.0
  changelog snapshot.
- [ ] Run final release validation and verify the archived bundle's export
  compliance metadata.
- [ ] Upload and validate build `1.2 (2)` in App Store Connect.
- [ ] Complete TestFlight verification on iPhone, iPad, and Apple Watch.
- [ ] Re-audit privacy answers, review notes, age rating, app icon, and
  availability for version 1.2.
- [ ] Upload and preview the 1.2 screenshot sets, select build `1.2 (2)`, and
  submit the phased release for App Review.

- [x] Select the final `1.1 (1)` build after App Store Connect finishes
  processing it. Selected on 2026-07-15. The previous `1.0 (1)` release used
  build ID `ccdc123f-9635-485c-b472-7b0093e026ac`.
- [x] Complete export compliance project prep for all four submitted executable
  bundles: the iOS app, iOS widget, Watch app, and Watch widget declare
  `ITSAppUsesNonExemptEncryption` as `false`. CodexBar uses only exempt Apple
  platform encryption such as HTTPS and Keychain; the Watch products do not
  perform provider networking or custom cryptography and receive or cache data
  through Apple system frameworks. Before uploading, run
  `./scripts/verify-export-compliance.sh source`, then run
  `./scripts/verify-export-compliance.sh bundle <path-to-CodexBarIOS.app-or-xcarchive>`
  against the built submission.
- [ ] Confirm the processed build's export-compliance answers in App Store
  Connect still match these four declarations before each submission; this
  remains a manual release step even though the bundle metadata is verified.
- [x] Complete content rights. App Store Connect records that CodexBar has the
  necessary rights to its third-party content.
- [x] Complete age rating. App Store Connect reports `4+`, and the 2026 social-media
  capability questions are answered `No`.
- [x] Complete review contact info.
- [x] Add App Review notes. The notes explain that the app opens without an
  account and that live provider cards require reviewer-owned provider
  credentials; the unnecessary review sign-in fields were removed.
- [x] Submit for review. Version 1.1 build `1.1 (1)` was submitted on
  2026-07-16.
- [x] Track the submission through approval and release. Apple's public
  listing reports version 1.1 as released on 2026-07-16; the live status was
  re-verified on 2026-07-28.

## CodexBar-Specific Risks

- Provider integrations depend on third-party services that may return different data by account type or region.
- Some providers may block automation-like auth flows. Review notes should clarify that CodexBar uses user-supplied credentials/API keys to fetch the user's own account data.
- Google Gemini's consumer usage meters use a guided private Google website
  sign-in and an undocumented `gemini.google.com` web contract. The app retains
  only the verified account's required session cookies in Keychain. Before
  submission, confirm the current Google terms and App Review position and
  preserve the credential-sensitivity disclosure. Live comparisons belong to
  Franz; fixture results are not proof of live Google approval or quota values.
  The integration must remain read-only and fail closed when its contract changes.
- Brand asset permissions need a careful pass before submission.
- Widgets must continue to show useful stale/error states because iOS controls refresh timing.
- OpenCode Go and Zen now have guided phone authorization and workspace
  selection without importing desktop credentials. Provider approval and
  account-specific access remain external dependencies; see
  [OPENCODE-SIGN-IN.md](OPENCODE-SIGN-IN.md) for the current contract and
  pending live checks.

## Nice-To-Have For A Future Release

- [ ] In-app demo/sample mode for App Review and first-run exploration.
- [ ] One-tap diagnostics export that redacts secrets.
- [ ] Provider connection health screen.
- [x] Deterministic App Store screenshot automation for the six-scene iPhone
  and iPad marketing set.
- [ ] Release archive script that uses the same signing assumptions documented in `AGENTS.md`.
