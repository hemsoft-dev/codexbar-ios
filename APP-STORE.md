# App Store Release Tracker

This document tracks the work required to ship CodexBar for iOS and iPadOS through TestFlight and App Store review.

Status last reviewed: 2026-10-16

## Current Status

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
- Release policy is unchanged: US$3.99, 175 available territories, automatic release
  after approval, immediate rollout and the existing star rating. Existing Mac,
  Vision Pro, public distribution and education-discount settings are preserved.
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

## Release Work

Version 1.3 is already public. Checked items below record completed release
history; unchecked items remain manual or App Store Connect work for a future
submission unless a version-specific note says otherwise.

### 1. App Store Connect Setup

- [x] Confirm Apple Developer Program membership and team ownership. Membership confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- [x] Create the App Store Connect app record. Created as `CodexBar Usage Monitor`, app ID `6787769891`, on 2026-07-05.
- [x] Confirm bundle ID, SKU, primary language, category, and age rating. App Store Connect uses bundle ID `com.hemsoft.CodexBarIOS`, SKU `codexbar-ios`, primary language `English (U.S.)`, primary category `Developer Tools`, secondary category `Utilities`, and age rating `4+`.
- [x] Decide initial availability: iPhone and iPad.
- [ ] Revisit pricing before a future release if a paid distribution plan is
  introduced; version 1.1 remains available under its current storefront
  pricing.

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
| Supports multiple accounts and provider groups | Current app configuration model | Say multiple accounts/groups, not team management or shared org administration. |
| Offers Home Screen and Lock Screen widgets | Widget extension and configurable widget surfaces | Say configurable widgets; do not promise real-time refresh because iOS controls widget timing. |
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

### Screenshot Regeneration Workflow

Use the deterministic simulator capture script whenever the App Store
screenshots need to be refreshed:

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
