# App Store Release Tracker

This document tracks the work required to ship CodexBar for iOS and iPadOS through TestFlight and App Store review.

Status last reviewed: November 22, 2026

## Post-launch status

**2.0 has launched.** Franz explicitly confirmed this in his
[November 15 progress request](https://discord.com/channels/268484937475293186/1562562816714473585/1571622861884493926).
The existing [October 23 readback](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6376812259)
records public 2.0.0 distribution at 11:56:39 AM EDT. This update reconciles
those records. A separate November 15 public-page observation is recorded
below; no fresh App Store Connect observation was performed.
Development source is **2.1.0 build 6, Unreleased**, distinct from distributed
**2.0.0 build 5**. The launch sequence below is retained history.

[Next-version preparation](https://github.com/hemsoft-dev/codexbar-ios/issues/568)
uses 2.1.0 for the merged provider and dashboard changes since shipped 2.0.
All fourteen active project configurations retain build 6. The
[changelog](CHANGELOG.md#210---unreleased) and local
[draft release notes](fastlane/metadata/en-US/release_notes.txt) describe this
development source. Build 6 is retained from the prior preparation. No new
upload-inventory check or release qualification was performed for this metadata
update.

Franz also [confirmed lifetime Pro on his production iPhone after the cutoff](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6551367292)
on October 31 at 8:37 PM EDT. This is a human-reported result without a
screenshot. It resolves that specific check, not new-customer commerce or
Family Sharing.

The [November 1 release hold](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6569029608)
still prohibits new versions, submissions, TestFlight uploads, pricing and
App Store Connect changes. Ordinary source work and reviewed merges continue.
The launch report does not lift that hold. Keep `T` fixed at October 31,
2026, 8:00 PM EDT and preserve Free pricing.

### Remaining work and next triggers

These are bounded follow-ups, not instructions to repeat the launch. Dated
evidence is retained below and in the existing issues.

| Existing issue | Remaining criterion | Owner and next actual trigger |
| --- | --- | --- |
| [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469) | None. Closed November 22 | Retained Pro product settings were reverified on November 22 via authorized read-only App Store Connect API GET readbacks ([receipt](docs/evidence/2026-11-22-asc-pro-readback.json)). Franz accepted the public App Store evidence (`Data Not Collected` and live Pro Monthly, Yearly and Lifetime IAPs) as sufficient disposition for the private privacy questionnaire and Paid Apps Agreement, which remain unverified directly via API. Small Business Program non-enrollment (November 20) and the canonical privacy URL change on the next-submission checklist stand. No ASC write occurred; the November 1 publishing hold is unchanged. |
| [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) | None. Closed on owner dispositions, November 20 | New-customer Free download and Pro screen reported as working by Franz. Production trial, Restore and family-device checks waived by Franz and left unverified. No production screenshots, by decision. All 175 public storefronts showed Free on November 19. Details are under "Owner dispositions, November 20". |
| [#409](https://github.com/hemsoft-dev/codexbar-ios/issues/409) | None. Closed as not planned, November 21 | Owner decision: Greptile support is removed from the app ([#594](https://github.com/hemsoft-dev/codexbar-ios/issues/594)). An upgrade deletes saved Greptile accounts and history and shows a one-time note. |
| [#548](https://github.com/hemsoft-dev/codexbar-ios/issues/548) | None. Closed on an owner decision, November 22 | Franz decided to keep Claude sign-in as it is, without contacting Anthropic, and accepted the risk with Anthropic's published credential guidance known ([decision](https://github.com/hemsoft-dev/codexbar-ios/issues/548#issuecomment-7076699406)). The app identifies itself truthfully and requests fewer scopes ([#589](https://github.com/hemsoft-dev/codexbar-ios/issues/589)). This records the owner's decision; it is not permission from Anthropic or a legal conclusion. Franz's general publishing hold from November 1 is separate and unchanged. |
| [#558](https://github.com/hemsoft-dev/codexbar-ios/issues/558), [#559](https://github.com/hemsoft-dev/codexbar-ios/issues/559), [#560](https://github.com/hemsoft-dev/codexbar-ios/issues/560) | None. Resolved November 20 | Fable reset wording and per-reset choice ([#587](https://github.com/hemsoft-dev/codexbar-ios/pull/587)) and the promotional credit row ([#588](https://github.com/hemsoft-dev/codexbar-ios/pull/588)) shipped from public implementations' evidence; their live checks are pending for Franz. No response reports usage per product, so #558 is closed as not planned ([#586](https://github.com/hemsoft-dev/codexbar-ios/pull/586)). |
| [#564](https://github.com/hemsoft-dev/codexbar-ios/issues/564), [#565](https://github.com/hemsoft-dev/codexbar-ios/issues/565) | Watch timing and synthetic billing-grace causes remain unqualified | Resume on new failing diagnostics or demonstrated interference. Retain the November 15 static diagnosis receipts and delivered same-payload metadata correction. Do not repeat unchanged investigation or run tests just to obtain green results. |

Build 5's hosted full UI gate **did not pass**. Shipping cannot satisfy that
historical criterion retroactively. Its release actor and explicit exception
rationale remain unverified. Retain the failure below; no historical rerun is
pending. Any future authorized candidate needs its own release qualification.

### Additional public storefront observations, November 15

The [anonymous public-page receipt](docs/evidence/2026-11-15-public-storefront-observations.json)
records explicit numeric-zero download offers for Afghanistan (AFG/af), Angola
(AGO/ao), Anguilla (AIA/ai) and Albania (ALB/al), between **7:37:44 PM and
7:37:48 PM EST**. Each response retained the requested country and app ID in
both its final and canonical URLs, the expected developer identity, and an
explicit price and currency. These four countries extend the older six-country
sample; they do not establish simultaneous visibility across all 175 territories.

The next request, UAE (ARE/ae), stopped at **7:38:08 PM EST** with
`TimeoutError: The read operation timed out`. No retry or subsequent request
was made. Four countries were observed, one failed and 170 were not attempted;
the other 171 offers remain unknown in this batch. The failed request is not
evidence that the app is unavailable or paid there. This snapshot cannot
establish any pre-cutoff price or regional transition timestamp.

The [manual collector](scripts/check-public-storefronts.py) validates app and
country identity, preserves raw responses and hashes, rejects missing prices,
and stops on the first failure. Its [territory mapping](docs/evidence/2026-11-15-storefront-territories.json)
covers exactly the retained October 29 inventory, using pinned Unicode CLDR
codes; Apple's `XKS` inventory entry maps to `xk` (CLDR `XKK`). That mapping
alone does not prove a listing exists. See the [reproduction instructions](scripts/PUBLIC-STOREFRONTS.md).

### Complete public storefront coverage, November 19

Two batches on November 19 observed an explicit numeric-zero download offer in
all 175 territories of the October 29 inventory.

| Batch, all times EST | Territories | Result |
| --- | --- | --- |
| [First receipt](docs/evidence/2026-11-19-public-storefront-observations.json), 10:31:34 AM to 10:33:21 AM | Full 175-territory manifest | 140 Free, AFG through SLE. The next request, El Salvador (SLV/sv), returned `HTTP Error 429: Too Many Requests`. 34 were not attempted. |
| [Second receipt](docs/evidence/2026-11-19-public-storefront-observations-remaining.json), 10:48:45 AM to 10:49:16 AM | [35-territory subset manifest](docs/evidence/2026-11-19-storefront-territories-remaining.json): SLV and the 34 not attempted | 35 Free, complete. |

Every observed page kept the requested country and app ID in its final and
canonical URLs, the expected developer identity, and an explicit price and
currency. No page showed a paid offer. The 429 was Apple's rate limit after
140 requests in 107 seconds; it says nothing about the El Salvador listing,
which the second batch then observed as Free.

No single batch covered the full inventory, so coverage is the union of the two
receipts, collected within 18 minutes of each other. This establishes public
Free visibility on November 19 only. It cannot establish visibility before the
cutoff, any regional transition time, or production purchase behavior.

An independent [retained US public-page receipt](docs/evidence/2026-11-15-public-us-disclosures.json)
also shows the Free/Pro description, eligible seven-day trial wording, renewal,
Restore and original-purchaser disclosures, and the public **Data Not Collected**
label. Its description links the canonical hemsoft-dev privacy document.
The file timestamp bounds capture completion at **7:34:29 PM EST**; it is not
a server timestamp. This advances only the public US disclosure portion of
#469. It does not verify the private privacy questionnaire, Paid Apps Agreement,
Small Business enrollment or current product settings. A correct description
link also does not establish the separate ASC `privacyPolicyUrl` field.

The [November 19 US page receipt](docs/evidence/2026-11-19-public-us-disclosures.json),
taken from the storefront batch's US response at **10:49:05 AM EST**, shows the
same nine disclosure phrases and the **Data Not Collected** label with no other
privacy category. The page's App Privacy section, where Apple renders the
developer's privacy policy link, still points to the old
`HemSoft/codexbar-ios` path. An anonymous request at **11:24:39 AM EST**
returned a 301 to the canonical `hemsoft-dev` document, which loaded. Readers
reach the right policy today; the saved URL is still the old one and stays a
#469 follow-up for a future editable app information record. This is a public
page observation, not an App Store Connect readback.

Collection is manual and has no automatic CI, timer or account integration.
Neither the source preparation nor this public-page snapshot qualifies or
authorizes a release. The production and account criteria that were still open
here are settled or reassigned under "Owner dispositions, November 20" below.

### Owner dispositions, November 20

Franz gave these answers on November 20, 2026 at about 7:50 PM EST
([#470 record](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-7054606032),
[#469 record](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-7054606399)).
They are his reports and decisions. None is an agent verification, an App Store
Connect readback or a retroactive pass of a missed launch requirement.

| Criterion | Disposition | Evidence standing |
| --- | --- | --- |
| New-customer production Free download and Pro screen | Reported as working | Human report without a screenshot; device and exact date not recorded |
| Production eligible trial and Restore | Waived | Unverified. Local StoreKit results do not establish production behavior |
| Family-device result | Waived | Unverified. No production Family Sharing pass is claimed |
| Production-device screenshots | Not supplied, by decision | Franz's written reports stand as the evidence |
| Small Business Program | Not enrolled, by choice | Franz's stated decision; not an enrollment-screen readback. The missed before-shipping timing does not pass retroactively |
| Canonical privacy policy URL | Change it with the next submission | The old address still redirected on November 20. Carried by the final submission checklist |
| Privacy questionnaire, Paid Apps Agreement, retained product settings | Resolved November 22 | Retained product settings reverified by read-only ASC API GET on November 22; Franz accepted the public App Store evidence for the private questionnaire and Paid Apps Agreement, closing #469 (see below) |

### Retained Pro product readback and #469 closeout, November 22

With Franz's explicit authorization on November 22, 2026 at 5:24 PM EST, read-only
App Store Connect API GET requests ([receipt](docs/evidence/2026-11-22-asc-pro-readback.json),
observed at **5:24:58 PM EST**, `2026-11-22T22:24:58Z`) reverified the retained
2.0 Pro configuration with zero ASC writes:

- App version `2.0.0` (`2c7b9bd4-b877-454d-a5a2-036b25a151f5`) remains
  `READY_FOR_SALE` with `MANUAL` release; the app price schedule retains 1
  manual and 174 automatic zero-price records (175/175 Free).
- Subscription group `22490183` (**CodexBar Pro**): Monthly (`6824195141`,
  `com.hemsoft.CodexBarIOS.pro.monthly`, `APPROVED`, `ONE_MONTH`, level 1,
  `familySharable: false`, 175 territories, USA `$1.99`, 0 introductory offers)
  and Yearly (`6824195239`, `com.hemsoft.CodexBarIOS.pro.yearly`, `APPROVED`,
  `ONE_YEAR`, level 1, `familySharable: false`, 175 territories, USA `$14.99`,
  175 `ONE_WEEK` `FREE_TRIAL` introductory offers starting `2026-10-18` with
  null end date).
- Lifetime non-consumable (`6824195355`, `com.hemsoft.CodexBarIOS.pro.lifetime`,
  `APPROVED`, `NON_CONSUMABLE`, `familySharable: false`, 175 territories, USA
  manual price `$29.99`).
- App-level subscription billing grace period remains `optIn: true`,
  `sandboxOptIn: true`, `SIXTEEN_DAYS`, `ALL_RENEWALS`.
- App info (`d080baf5-aca3-4569-bc40-ec657e5bb125`) remains
  `READY_FOR_DISTRIBUTION` with en-US `privacyPolicyUrl` still set to
  `https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md`. An anonymous
  check at 5:21 PM EST confirmed the `HTTP/2 301` redirect to
  [PRIVACY.md](https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md),
  and the URL update stays on the final submission checklist for the next
  editable submission.

Because Apple's App Store Connect REST API does not expose the private App
Privacy questionnaire or Paid Apps Agreement status, those two web-portal
records remain unverified directly. On November 22, 2026, Franz accepted the
public App Store evidence checked at 5:21 PM EST (`2.0.0`, `Free`,
`Data Not Collected`, and live `Pro Monthly`, `Pro Yearly` and `Pro Lifetime`
IAPs) as sufficient disposition to close [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469).
The November 1 publishing hold is unchanged.

Fixed `T`, the rule never to raise the app price after `T`, the recorded hosted
release-gate failure and the November 1 hold are unchanged.

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

Free is configured for all 175 territories in the October 29, 2:55 PM EDT
App Store Connect readback below. Live App Store pages showed Free in six
sampled storefronts by October 30, 9:0x AM EDT, while the lookup API lagged.
The October 31, 8:30 PM EDT live-page check still showed Free after cutover T.
The earlier US$3.99 rollout remains recorded as history. This documentation update makes no App Store Connect write. [Issue #469](https://github.com/hemsoft-dev/codexbar-ios/issues/469)
owns remaining account and disclosure verification;
[issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) owns the
remaining post-launch production checks. Submission, observed release and
the Free transition are recorded outcomes, not pending launch work.

### Post-cutover storefront record, October 31

The compiled cutoff **T was Saturday, October 31, 2026 at 8:00 PM EDT**.
The observed public release time was **October 23, 11:56:39 AM EDT**, more than
six full days before T. That is Apple's reported public release time, not a
verified manual-release action timestamp. The distributed app is **2.0.0 build
5**, source `62f6d8e392360b91cb704c2503e9796f8ddc285c`.

Franz set Free on October 29, reporting his action at 2:54 PM EDT. The ASC
schedule readback at **2:55:54 PM EDT** confirmed current zero-price records in
all 175 territories. Every start and end date was null, so the exact regional
effective times remain unavailable. This was later than the October 28,
8:00 PM EDT target. Free was visible on the six sampled live pages before T;
no removal contingency was triggered in the recorded follow-up. The app must
remain Free and T must remain fixed.

The checks below cover US, CA, GB, DE, JP and AU. Paid lookup amounts were
USD 3.99, CAD 4.99, GBP 3.99, EUR 3.99, JPY 600 and AUD 5.99, respectively.
A cached lookup result and a live-page offer are separate observations.

| Observation, all times EDT | Source | Result across the six sampled storefronts |
| --- | --- | --- |
| October 29, 2:48 PM | [Pre-change lookup receipt](docs/evidence/2026-10-29-store-checkpoint.json) | All 2.0.0, all paid at the amounts above. |
| October 29, batch began 2:55:54 PM | [Post-schedule lookup receipt](docs/evidence/2026-10-29-storefronts-after-schedule.json) | All 2.0.0, all still paid after ASC confirmed Free. |
| October 29, 8:00:19 PM | [Evening lookup check](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6511426972) | All 2.0.0, all still paid at the amounts above. |
| October 30, 9:00:28 AM | [Morning lookup check](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6523439029) | All 2.0.0, all still paid at the amounts above. This API result did not establish the current live-page price. |
| October 30, 9:0x AM | [Live-page correction and ASC readback](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6523449987) | All six live pages had schema.org offers with numeric price 0 in their local currencies. Lookup still showed paid. USA ASC manual price was 0.0 with no start/end date. |
| October 31, 8:30 PM, after T | [Chief's live-page check](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6551194058) | All six live pages had numeric offer price 0. US, CA, GB, DE and AU printed 2.0.0; JP did not print a version. |

The first recorded live-page Free observation for each of
[US](https://apps.apple.com/us/app/id6787769891),
[CA](https://apps.apple.com/ca/app/id6787769891),
[GB](https://apps.apple.com/gb/app/id6787769891),
[DE](https://apps.apple.com/de/app/id6787769891),
[JP](https://apps.apple.com/jp/app/id6787769891) and
[AU](https://apps.apple.com/au/app/id6787769891) is October 30, **9:0x AM EDT**.
The exact minute and actual public price-change instant are unknown. The
9:01:04 AM comment timestamp is a posting time, not an exact observation time.
The six-country sample does not prove public visibility in all 175 territories.
The October 31 result records the Chief's check, not a new check by this agent.
No ASC, price or availability changes were made for this verification.

### Post-cutover simulator verification

On October 31, **20:40:13 EDT to 20:41:02 EDT**, the strict native capture
passed on an owned iPhone 17 simulator with iOS 26.2 / 23C54 and Xcode
26.6 / 17F113. This was development source **2.0.1 build 6**, based on
`6571be9`, not an execution of the distributed 2.0.0 build 5 binary.
The [sanitized verification receipt](docs/evidence/2026-10-31-post-cutover-verification.json)
records source-file hashes, exact selectors and results. Screenshots and the
interaction recording accompany the issue's record-keeping PR.

- A fresh isolated app namespace launched after T without a Pro interstitial.
  Settings opened the Pro screen showing **Free plan**, one account and seven
  days of history, with monthly, yearly and lifetime purchase choices.
- Empty Restore returned **No Pro purchase found** and kept the Free plan.
- The native eligible yearly offer showed **7 days free, then $14.99 per year**
  and **Start 7-day free trial**. Purchase activated **Pro free trial**.
- After relaunch without resetting storage, Restore returned **Purchases
  restored** and retained the trial. The saved entitlement environment was
  `xcode`, with reason `trial`.
- Two focused synthetic UI tests passed eligibility variants and distinct empty,
  canceled and failed Restore states. Seven original-purchaser policy tests
  passed the compiled cutoff, strict at/after-T production date boundary and
  sandbox/Xcode exclusion. Pinned lint and all four CI-policy tests passed.

Image 04 was recaptured on October 31 at **11:33:48 PM EDT** using the
existing manual native StoreKit product capture. The earlier images 03 and 04
were byte-identical. The replacement [yearly-offer screenshot](https://github.com/user-attachments/assets/c5f9e19a-2b48-46bf-8226-919b18865cb6)
shows the full yearly row, **7 days free, then $14.99 per year**, and
**Start 7-day free trial**. Capture waited for the resolved Pro screen and the
entire product row to fit inside the viewport. The screenshot and exported
accessibility text were inspected; the capture passed 1/1 with no failures or
skips and attempted no purchase. The receipt records the replacement hash,
attachment URL and provenance separately from the original 8:40 PM run. App,
test and CI code are unchanged. Franz's production-device check stays pending.

The first capture failed when empty Restore presented Apple's sandbox sign-in
prompt and cancellation returned **Restore canceled**. That failure is retained.
After stopping only the owned simulator's storekitd and rerunning separate
empty-store preparation, the strict final capture passed without accepting
cancellation as an alternative. A separate release-manifest self-check remains
34/35 because base `6571be9` already contains a Claude evidence method missing
from its manifest. This work does not claim full release qualification.

The opt-in capture in [ProCommerceNativeJourneyTests](CodexBarIOSUITests/ProCommerceJourneyTests.swift)
uses the production StoreKit adapter and entitlement service with UUID-isolated
storage and the checked-in [local StoreKit configuration](StoreKit/CodexBarPro.storekit).
Provider data is synthetic and provider networking is blocked. This adds no
consumer infrastructure dependency or automatic CI workload.

Build the native scheme and run its empty-store preparation in a separate
process, following the [local validation procedure](docs/2026-10-18-pro-commerce-validation.md).
For this capture only, copy the generated `.xctestrun` beside the original and
set `CodexBarIOSUITests.EnvironmentVariables.CODEXBAR_POST_CUTOVER_CAPTURE`
to `1`. Execute that copy with the exact selector
`CodexBarIOSUITests/ProCommerceNativeJourneyTests/testPurchaseAndRestore`.
The ordinary release-manifest selector keeps its existing lifetime journey
when the flag is absent. Reset local transactions with the separate preparation
test after capture.

Franz's own production-device check of a new Free download, Pro, eligible trial
and Restore remains pending. Local Xcode StoreKit cannot establish production
purchase eligibility, original-purchaser recognition or Family Sharing. Franz's
[October 25 original-purchaser pass](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6401351346)
is a separate historical result, followed by his confirmed October 31,
8:37 PM EDT post-T pass linked above.
The family-device check remains unverified.

### October 29 confirmed Free configuration

Franz reported completing the Free change at **2:54 PM EDT**. A read-only ASC
readback completed at **2:55:54 PM EDT**, `2026-10-29T18:55:54Z`, confirms:

- One manual USA price and 174 automatic regional prices, 175 distinct
  territories, exactly matching the prior 175-territory inventory.
- Every `customerPrice` is numeric zero, encoded as `0` or `0.0`, equivalent
  to 0.00 in its local currency.
- Every `startDate` is `null` and every `endDate` is `null`. These are current,
  open-ended price records, with no future dated Free entry. The API does not
  expose the exact effective start timestamp; do not substitute the observation
  or Franz's reported action time for a scheduled start date.
- Both collections fit in one page each, with no next page. There are no paid
  entries at all, including no conflicting future paid entry. Missing
  territories: **none**.

The [per-territory receipt](docs/evidence/2026-10-29-free-schedule-readback.json)
records every territory, price and null date, the expected inventory and page
counts. All requests were GETs through the existing app-manager credential.
No ASC state was changed by this agent.

The [six-country public lookup receipt](docs/evidence/2026-10-29-storefronts-after-schedule.json)
still reports paid 2.0.0 in US, CA, GB, DE, JP and AU at this checkpoint. The
lookup batch began at 2:55:54 PM EDT after the schedule readback. A correct ASC
schedule does not prove public display propagation has completed. The completed
October 29 evening and October 30 morning follow-ups are recorded above, including the later live-page correction. The exact
display-change time and all-territory public visibility remain unverified.

The earlier hold for an ASC Free readback is satisfied. The Chief owns guarded
merge after clean final-head review and required SwiftLint. The six-country
public Free sample is complete. All-territory public visibility and post-cutoff
production checks remain unverified under
[#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470).

### October 29 pre-change checkpoint, retained history

This earlier checkpoint observed paid pricing before Franz's action above.
All Apple calls in this work were GET requests.

At 2:48 PM EDT, `2026-10-29T18:48:15Z`, iTunes lookup returned:

| Country | Version | Download price |
| --- | --- | --- |
| [US](https://itunes.apple.com/lookup?id=6787769891&country=us) | 2.0.0 | USD 3.99 |
| [Canada](https://itunes.apple.com/lookup?id=6787769891&country=ca) | 2.0.0 | CAD 4.99 |
| [UK](https://itunes.apple.com/lookup?id=6787769891&country=gb) | 2.0.0 | GBP 3.99 |
| [Germany](https://itunes.apple.com/lookup?id=6787769891&country=de) | 2.0.0 | EUR 3.99 |
| [Japan](https://itunes.apple.com/lookup?id=6787769891&country=jp) | 2.0.0 | JPY 600 |
| [Australia](https://itunes.apple.com/lookup?id=6787769891&country=au) | 2.0.0 | AUD 5.99 |

All six report the public release instant October 23, 11:56:39 AM EDT.
The sales credential returned 403 for the price schedule. An existing local
app-manager credential returned 200: one manual USA price, customer price
3.99, null start/end dates; 174 automatic regional prices, no pagination,
and no zero-price point or future Free entry in either collection.
This confirms no scheduled Free change at this observation, rather than
inferring it from the six public prices. Credentials and tokens are excluded.
Sanitized receipts are in [the checkpoint evidence](docs/evidence/2026-10-29-store-checkpoint.json).

The intended T-minus-72-hour target was October 28, 8 PM EDT and is missed.
The pre-change instruction was for Franz to set Free immediately in
[App Store Connect pricing](https://appstoreconnect.apple.com/apps/6787769891/distribution/pricing).
The confirmed configuration above supersedes that pending action.
For this incident, the latest conservative decision time is **October 29,
8 PM EDT**, T minus 48 hours. This preserves the plan's removal window if Free
cannot be established. Select the earliest available effective date and inspect
the latest regional start. Do not choose October 31 merely because T falls on
that local calendar date.

The mathematical last bound is strictly before **October 30, 8 PM EDT** for
the *latest storefront's effective start*, allowing Apple's stated 24-hour
display delay. That is not a safe deadline to begin scheduling: regional starts
vary, and there would be no removal margin. Apple's
[regional timing guidance](https://developer.apple.com/help/app-store-connect/reference/pricing-and-availability/app-store-pricing-and-availability-start-times-by-country-or-region)
says already-passed scheduled times take effect immediately but can take up to
24 hours to display. A universally safe future calendar date cannot be certified
without the regional preview. If the preview/readback cannot establish Free
before T, Franz must use the approved removal contingency by October 29, 8 PM
EDT and verify several storefronts. This task authorizes neither action by agents.

At **October 31, 8 PM EDT**, `2026-11-01T00:00:00Z`, the binary does not change
the App Store price or grant access based on money charged. A first acquisition
of build 5 at or after T fails the strict `originalPurchaseDate < T` check and
the paid-version check, which accepts integer builds through 4 or dotted
versions below 2.0. Without a separate verified Pro entitlement, that customer
gets one active account and seven days of history even if Apple charged $3.99.
They must purchase Pro to unlock Pro features unless support remedies the case.
Qualifying earlier acquisitions, including deliberate free downloads before T,
keep lifetime Pro; later reinstalls retain original purchase evidence. T must
remain fixed. Never raise the price after T.

The confirmed readback above records Free with null start/end dates. Exact
regional effective timestamps are not supplied by these API records. Fresh
zero-price public storefront observations remain pending.
The six-country sample does not prove all 175 sale territories. Leave the
all-storefront and post-T checks open until their evidence exists. Record the
hosted UI gate as failed, with the historical release decision unverified;
[the final hosted receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6355906921)
reports one failure per family. Shipping is not evidence that the gate passed.

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
`153c92f1-497a-43d5-8902-92030fd8ef1f`.
The monthly, yearly and lifetime version records are respectively
`c8c9fb7c-663f-48c7-b3af-79bb63ba5cb3`,
`8acbb0ea-aaaf-46f4-9147-f5122af71820` and
`a29cfae6-d318-419f-9865-9a34a257f0e1`. The group version and all three
product versions were submitted with app version 2.0 on October 22, 2026 and
read back as `WAITING_FOR_REVIEW`. Submission does not mean approval.

Family Sharing is off for all three products. Both subscriptions retain
Apple's default multiseat `ENABLED` setting and use ordinary full-period
payment, `UPFRONT`. The separate app-level billing grace record enables
`SIXTEEN_DAYS` for `ALL_RENEWALS` in production and sandbox. The six audited
app-download pricing and availability collections are unchanged, including
the US$3.99 download price and 175 sale territories. Preserve these settings
through the approved launch sequence.

App version `2.0.0`, ID `2c7b9bd4-b877-454d-a5a2-036b25a151f5`, uses build 5
(`e224b2b9-c59a-44ff-bd92-d1ed7a0f6b02`, `VALID`) from source
`62f6d8e392360b91cb704c2503e9796f8ddc285c`, with `MANUAL` release and no phased
release. Review submission `af75f0db-4b2c-403d-81e2-c3b14ab05986` was submitted
on October 22, 2026 at 8:20 AM EDT, `2026-10-22T12:20:11Z`. It holds five
items: the app version, the CodexBar Pro group version, and the monthly, yearly
and lifetime versions. The October 29 GET readback confirms version `READY_FOR_SALE` and all three
products `APPROVED`. The launch is complete; use the
[post-launch status](#post-launch-status) for remaining work. The three local
StoreKit review screenshots demonstrate app UI and test-configuration prices.
They do not establish live App Store prices or production original-purchaser
access.

Apple's [first-submission website instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)
and [subscription guidance](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review.md)
require the first products to accompany an app version in one submission. On
October 22 the website omitted the ready subscriptions and its submit failed.
The review-submission API succeeded once the draft also held the group's
`subscriptionGroupVersion`. The [release skill](.agents/skills/app-store-release/SKILL.md)
documents that fallback. Never remove items from a draft that holds first-time
products.

The [October 21 scope record](docs/2026-10-21-pro-scope-decisions.md) keeps
Pro Apple-local and native Mac qualification provisional.

The submitted 2.0 [description](fastlane/metadata/en-US/description.txt),
[promotional text](fastlane/metadata/en-US/promotional_text.txt),
[release notes](fastlane/metadata/en-US/release_notes.txt) and
[review notes](fastlane/metadata/review_information/notes.txt) were read back
on October 22, including the 1,845-character What's New text. The linked
working files now include later preparation; release notes were aligned to
Unreleased 2.0.1 in [PR #539](https://github.com/hemsoft-dev/codexbar-ios/pull/539).
The current draft now covers Unreleased 2.1.0 under
[#568](https://github.com/hemsoft-dev/codexbar-ios/issues/568). These working
files are not a snapshot of live metadata. The description includes Apple's
[standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
and the public [privacy policy](https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md).
The existing GitHub privacy and support URLs remain the release destinations.

The [build 6 preparation record](docs/2026-10-23-build6-release-preparation.md)
is superseded: Franz kept build 5 and build 6 was never uploaded
([#515](https://github.com/hemsoft-dev/codexbar-ios/issues/515)).

### Cutover and original-purchaser rules

The submitted release is `2.0.0 (5)`, built from
`62f6d8e392360b91cb704c2503e9796f8ddc285c`. The project now carries build
number 6 so that any later upload is numbered above build 5.
The [2.0 changelog](CHANGELOG.md#200---2026-10-23) is dated with the
observed public release date, October 23; submission was October 22.
The [privacy policy](PRIVACY.md) is effective
October 18; that date does not record App Store submission or distribution.
The cutoff `T` compiled into build 5 is **final: October 31, 2026 at 8:00 PM
EDT**, which is `2026-11-01T00:00:00Z`. It cannot change without a new binary.
The value in
[ProOriginalPurchaserPolicy](CodexBarIOS/Services/ProOriginalPurchaserPolicy.swift),
the original-purchaser notice, the support page, the promotional text, the
release notes and the review notes all name this instant. Do not move `T` in a
later 2.0.x update; that would change who qualifies after 2.0 is distributed.

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

Family members of original purchasers must install before October 31, 2026 at
8:00 PM EDT, `2026-11-01T00:00:00Z`.
The [support page](SUPPORT.md#codexbar-pro-and-restoring-purchases) explains the
one-time free lifetime offer-code route for missed cases. No codes are created
or distributed by this disclosure work. Franz confirmed production original-purchaser lifetime Pro on October 25
([receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6401351346)).
The family-device check remains pending; local StoreKit tests do not prove it.
Those production checks belong to Franz and are not prerequisites for
agent-owned implementation or automated delivery.

### Approved launch sequence

Historical procedure for the completed 2.0 launch. Its dates and conditional
rollback branches must not be reused as authority for future store actions.
The [post-launch status](#post-launch-status) records remaining work and the
standing release hold.

1. Before submission, set `T` to 00:00 UTC fourteen calendar days after the
   planned submission date. Confirm that the 1.4.0 review is finished. Require
   version 2.0.0 and build 5 or higher across the app and embedded products,
   then verify the built archive rather than relying only on project text.
   Recheck the cutoff disclosures, the privacy policy's effective date and
   the [2.0 changelog](CHANGELOG.md#200---2026-10-23) against the final candidate.
2. Submit 2.0 and all first Pro products together through the
   [App Store Connect website](https://appstoreconnect.apple.com).
   Verify the subscription group and all three products are in the same draft
   as the app version before submitting. If the website hides ready products,
   use the API fallback in the [release skill](.agents/skills/app-store-release/SKILL.md).
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

The [approved rollback plan](docs/2026-10-16-codexbar-pro-plan.md#rollback)
distinguishes two cases. Before any Free transition, if paid distribution
cannot end safely before `T`, remove the app from sale at least 48 hours before
`T`, verify removal in several storefronts, and keep it off sale until the
plan's replacement-build recovery is ready. That historical before-price-change
branch specifies a 2.0.1 with a later cutoff. After the Free transition, existing
grants stay granted; never raise the price or extend `T` to restore paid sales,
since doing so would grant lifetime Pro to intervening free downloads. Remove
the app from sale if acquisition must stop. The current confirmed Free
configuration uses this after-price-change branch. T remains fixed.

| Checkpoint | Requested action and time | Actual App Store Connect time | Storefront observations | Source SHA / build / T | Pending Franz checks |
| --- | --- | --- | --- | --- | --- |
| Final candidate and cutoff | Freeze build 5 | Uploaded October 19, 7:12 PM EDT; `VALID` | Not applicable | `62f6d8e` / 2.0.0 (5) / `2026-11-01T00:00:00Z` | None |
| Exact-candidate qualification | Before release | Local gates passed October 19; hosted full UI gate did not pass, including the final October 23 receipt; release decision rationale unverified | Not applicable | `62f6d8e` / 2.0.0 (5) | Live provider comparisons remain separate |
| Manual submission | App 2.0 plus all first products; paid price; no phased release | Submitted October 22, 2026 at 8:20 AM EDT (`2026-10-22T12:20:11Z`); review submission `af75f0db`, Waiting for Review | US$3.99 retained | `62f6d8e` / 2.0.0 (5) / `2026-11-01T00:00:00Z` | Small Business enrollment (optional) |
| Manual release | No later than October 25, 8 PM EDT | Observed public October 23, 11:56:39 AM EDT, `2026-10-23T15:56:39Z`; actor/action timestamp unverified | 2.0.0 in six countries October 29 | Same build | None |
| Propagation | Wait full 48 hours after release | October 29 readback exceeds 48 hours | US, CA, GB, DE, JP, AU all 2.0.0; not proof of every territory | Same build/T | None |
| Free schedule | Franz reports completed October 29, 2:54 PM EDT; target October 28 was missed | GET confirms 175/175 current zero-price records at 2:55:54 PM EDT; all start/end dates null | Six live pages Free by October 30, 9:0x AM EDT while lookup lagged; still Free October 31, 8:30 PM EDT | Same build/T; per-territory receipt above | All-territory public visibility unverified |
| Post-cutoff | After October 31, 8 PM EDT | T passed; no ASC mutation in this verification | Six live pages Free at 8:30 PM EDT; simulator evidence above is separate; Franz reported original-purchaser lifetime Pro at 8:37 PM EDT | Distributed 2.0.0 (5), same T; simulator source recorded above | Own-device new Free download, Pro, trial, Restore and family-device checks |

Launch and price transition are complete. The remaining post-cutoff checks
stay open individually. Completed and remaining actions follow:

- [x] Freeze build 5 at `62f6d8e` and verify the cutoff, release copy and built
  `2.0.0 (5)` versions.
- [x] Pass the local release gates on Xcode 26.6 / 17F113 with iOS 26.2,
  including native commerce, both UI families and function risk.
- [ ] Pass the hosted release gate for exact SHA `62f6d8e`
  (tag `v2.0.0-build5`). This historical requirement was not satisfied before
  release. All five quality jobs passed in
  [run 39779930660](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39779930660),
  but the full UI gate did not pass. The
  [final UI receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6355906921)
  reports one failure in each family. Public release is observed; its actor,
  explicit gate exception and decision rationale remain unverified. No pending
  rerun or future decision is implied, and this box must remain unchecked.
- [x] Archive, export, upload and verify processing, then select that exact build.
- [x] Submit app version 2.0, the CodexBar Pro subscription group and all three
  products once (review submission `af75f0db`, October 22).
- [x] Record approval and observed public distribution before the deadline.
  [October 23 receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/470#issuecomment-6376812259);
  the agent did not release the app.
- [x] Wait 48 hours and record six storefront observations serving 2.0.
- [x] Record the Free configuration in all 175 territories and the six-country
  live-page Free sample before T. Exact regional effective times and pre-T
  public visibility in every territory remain unverified.
- [x] Record Franz's October 31 post-cutoff original-purchaser lifetime-Pro
  confirmation, attributed as a human report without a screenshot.
- [x] Record new-customer production Free download, Pro screen, eligible trial
  and Restore results. Franz reported the Free download and Pro screen as
  working on November 20, without a screenshot. He waived the production trial
  and Restore checks, which stay unverified. The simulator evidence above is
  separate.
- [x] Record the family-device result. Franz waived it on November 20. No
  production Family Sharing pass is claimed.

### Build 5 qualification and submission

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
Franz submitted build 5 on the local exact-source passes. The hosted gate
did not pass before distribution. Later attempts and failures are recorded
above; no further same-SHA rerun is pending.

The build 5 archive and export passed signature, provisioning, bundle-version,
privacy-manifest and export-compliance verification. The IPA SHA-256 is
`819b38cc6bb45f1ea6bd90bc1f34af3a70b39eedb4fe3cd248692f69ea0293ec`.
It was uploaded October 19 at 7:12 PM EDT, processed as `VALID`, and selected
on the draft. TestFlight serves build 5 to the internal group. Build 5 was
also submitted for TestFlight beta review on October 22 at 12:09 UTC so an
external Family group can test it; that review is separate from App Review.

Franz directed submission of build 5 on October 22, 2026. The App Store
Connect version page omitted the first auto-renewable subscriptions, and its
submit action failed. The API submission succeeded after the review submission
held five items: app version 2.0, the CodexBar Pro `subscriptionGroupVersion`,
Monthly, Yearly and Lifetime. A first-time group rejects its subscriptions
without the group version
(`STATE_ERROR.SUBSCRIPTION_SUBMISSION_REQUIRES_GROUP_VERSION`). Never remove
items from a first-product draft; removed products can stay locked.
Build 6 preparation, including a November 6 cutoff, was dropped and never
uploaded. Release, pricing, availability and spending still require Franz's
authorization under the standing release hold. This paragraph records the
October submission history, not current permission to repeat it.

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

The launch plan used family-deadline promotional text before `T`. The following
evergreen copy remains a draft for a future authorized metadata update, after
worldwide Free is verified:

```text
Start free with one AI account and 7-day history. CodexBar Pro adds all accounts, widgets, Watch, alerts and 90-day history. Original purchasers keep lifetime Pro.
```

That update should remove the expired family-install request from What's New.
Keep the historical deadline and offer-code help in support copy.
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
On October 29, 2026 the published US page showed Data Not Collected; see the
[acceptance checkpoint](docs/2026-10-29-pro-acceptance.md#live-product-page-and-privacy).
That check also found the App Store Connect privacy URL still on the old
`HemSoft/codexbar-ios` path.

The release owner's separate [app-information audit](/tmp/codexbar-470-app-info/audit.json)
passed 17 checks over seven complete read-only collections observed on
October 18 at 7:45:40 AM EDT, `2026-10-18T11:45:40Z`. Distributed and editable
app information agrees on Developer Tools / Utilities, the base 4+ rating,
en-US name and subtitle, and the saved
[privacy URL](https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md).
These fields do not verify the unpublished privacy questionnaire, legal
agreements or Small Business Program status.

Paid Apps Agreement status remains **UNVERIFIED** directly via App Store Connect
(on November 22, 2026, Franz accepted live public Pro IAP availability as
sufficient disposition to close [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469)).
On November 20, 2026 Franz
stated that he is not enrolled in the
[Small Business Program](https://developer.apple.com/app-store/small-business-program/),
by choice. That is his decision as stated, not an enrollment-screen readback.
The original before-shipping enrollment timing was missed or unverified and
cannot be satisfied retroactively. Do not infer current agreement status from
historical sales or the launch. These account checks do not
prevent ordinary source preparation, and authorize no account or Store change.

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
| Tracks ChatGPT / Codex, GitHub Copilot, GitHub Billing, Claude, Grok, X Subscription, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot (Kimi) | Current provider list used by the app; metrics vary by account and service | Name exactly these providers; do not imply official affiliation or complete metric availability. |
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

4. `grok` in dark appearance

5. `github-billing` in light appearance

6. `widget-builder` in light appearance

7. `accounts` in dark appearance

8. `provider-copilot` in light appearance

9. `history` in dark appearance

The provider scenes put the selected synthetic account first in the actual
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
- [ ] While the app information is editable for the next submission, change the
  saved privacy policy URL to
  `https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md` and record
  the readback. The saved value is still the old `HemSoft/codexbar-ios` path
  ([#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469)). Remove this
  line once it is done.

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

- Brand asset permissions need a careful pass before submission.

- Antigravity is experimental and has no authorization from Google
  ([#601](https://github.com/hemsoft-dev/codexbar-ios/issues/601),
  [decision record](docs/2026-11-23-antigravity-web-session-decision.md)).
  Guideline 5.2.2 lets App Review ask for it. The review notes in
  `fastlane/metadata/review_information/notes.txt` say what the app reads and
  that no authorization exists. If Apple asks for authorization, stop and
  report on #601; a request to Google is drafted only then. The description
  lists Antigravity as experimental. Do not submit a build with Antigravity
  until the feasibility gate on #601 has passed. No Antigravity mark or logo is
  used in the app or its screenshots.

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
