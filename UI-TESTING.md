# Isolated account UI tests

`CodexBarIOSUITests` drives the rendered app with XCTest on iPhone and iPad.
Run both destinations with the active Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-ui-tests.sh
```

Pass `iphone` or `ipad` to run one family. The runner selects the newest
installed iOS runtime compatible with the active simulator SDK. Set
`UI_TEST_DEVICE_NAME` or `UI_TEST_DEVICE_ID` to choose an available simulator
when running a single family. The default `all` mode rejects these overrides
before launching either destination.
`UI_TEST_RESULTS_DIR` changes the output directory, which defaults to
`build/ui-tests`. Each invocation creates a fresh result directory and retains
the build log, result bundle, and summary. On failure it also exports screenshot
attachments and the accessibility hierarchy from the result bundle. Open the
`.xcresult` in Xcode to inspect each action and assertion.

## Complete release phases

The base command above still executes exactly 29 original journeys. The
[phase manifest](scripts/pro-release-phases.json) requires 53 user journeys per
family for a release: original 29, supplemental 8, synthetic commerce 14, and
native purchase/restore and purchase-error journeys 1 each. The separate
marketing capture method is excluded. Normal preparation, purchase-error
preparation and a final normal reset add three separate XCTest invocations;
they are not counted as user journeys.

Run the complete family from a clean committed checkout with pinned Xcode
26.6 / 17F113 and iOS runtime 26.2 / 23C54 (see FUNCTION-RISK.md):

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
ui_run="$(mktemp -d /tmp/codexbar-ui.XXXXXX)"
./scripts/run-pro-release-validation.sh provision --family iphone --output "$ui_run/device"
ui_device_id="$(jq -r .device.deviceId "$ui_run/device/ownership.json")"
UI_TEST_REQUIRE_DEVICE_ID=1 UI_TEST_DEVICE_ID="$ui_device_id" \
  UI_TEST_OWNERSHIP_RECEIPT="$ui_run/device/ownership.json" \
  UI_TEST_RESULTS_DIR="$ui_run/base" ./scripts/run-ui-tests.sh iphone
./scripts/run-pro-release-validation.sh ui --family iphone \
  --ownership "$ui_run/device/ownership.json" --base-results "$ui_run/base" \
  --output "$ui_run/commerce"
./scripts/run-pro-release-validation.sh shutdown --family iphone \
  --ownership "$ui_run/device/ownership.json" --output "$ui_run/shutdown"
```

Repeat with `ipad` and fresh directories. Always shut down the owned simulator
when an earlier command fails. Never erase or reuse another task's simulator.
The ownership receipt binds the exact installed runtime bundle path and build.
If multiple builds share a runtime version, provisioning requires an observed
`--runtime-build`; it never chooses the first matching version. Standalone base
runs reject an ambiguous runtime unless given `UI_TEST_OWNERSHIP_RECEIPT`.
The ownership receipt and an immutable native-use marker prevent reuse after
an interrupted or failed native run. Shutdown is still allowed. The runner
attempts the final StoreKit reset after native UI preparation/execution fails,
retains both failures, and preserves the original exit code. A reset failure
fails qualification even if the journeys passed.

Each phase enumerates the built tests and checks exact identities, passing
counts, zero skips/expected failures and one expected destination. It records
source and binary hashes, signing, commands, timestamps, summaries and xcresults.
The supplemental six reuse the verified base build; native hosts are separately
built with coverage, the Debug isolation flag and ad hoc signatures. Each
preparation exits before its consumer starts. Every native scheme execution is
explicitly filtered. Fresh DerivedData lives inside each unique output directory;
`UI_TEST_DERIVED_DATA_DIR` is no longer used.

These commands add no automatic CI work. See [function coverage](FUNCTION-RISK.md)
and [native commerce validation](docs/2026-10-18-pro-commerce-validation.md) for
the separate unit-coverage phases and retained StoreKit failures. A local run
with `--supplementary` is not release qualification.

## Journeys

For focused Cursor renewal validation, set
`CODEXBAR_UI_TEST_SUBJOURNEY=cursor-renewals` on the existing
`CodexCreditsPoolUITests.testCompactCardHeadersAndIndependentControls` test
runner. It uses the production Cursor provider with intercepted native, web and
Stripe responses. Captures cover monthly/annual, expanded/collapsed, exact dates,
canceled/unavailable/stale/past details and persisted Dashboard hiding in both
light/default and dark/accessibility text on iPhone and iPad. This remains a
local/manual journey and adds no automatic CI work. Use an `.xctestrun` test
configuration's `EnvironmentVariables` to pass the selector when using
`test-without-building`.

Each test starts with a new UUID storage namespace and uses accessibility text
size 2, English labels, and the US locale. Navigation uses the real views and
actions. Tests wait for settings destinations, keep text fields inside the
visible form below its navigation bar, and wait for the keyboard before
entering text. An unfocused iPad detail field gets one additional tap, and the
keyboard must still appear before typing. Scroll gestures stay inside the
containing scroll view so an iPad sheet scrolls instead of the dashboard behind
it. Animations retain the normal app behavior.

- `CodexCreditsPoolUITests.testCompactCardHeadersAndIndependentControls`
  captures expanded/collapsed cards in light/dark appearance at default and
  accessibility text size 2, with and without plan badges. It checks 44-point
  menu targets, independent expansion, metric details, Customize Card, a saved
  half-width ring and a long account title after relaunch, plus stale refresh.
  Run locally with
  `-only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testCompactCardHeadersAndIndependentControls`.
  This journey is manual/release-only, not part of automatic PR or main CI.

  The native journey checks controls and saves captures. It does not assert
  the title's rendered ink position; the separate local pixel command is the
  pass/fail spacing regression check and must accompany spacing validation.
  This avoids treating an accessibility container's frame as the title ink.

  The local-only pixel check needs Python 3 and Pillow. Export its PNG
  attachments, then measure the first unscrolled Codex card's title gap:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcresulttool \
    export attachments --path <result.xcresult> --output-path <attachments-dir>
  python3 scripts/check-card-top-spacing.py --scale 3 <iphone-default-light.png>
  python3 scripts/check-card-top-spacing.py --scale 2 <ipad-default-light.png>
  python3 scripts/manual-tests/test_card_top_spacing.py -v
  ```

  The expected native portrait widths are 1206 and 2064 pixels. Use `--theme
  dark` for dark captures. The check rejects a title gap outside 14–28 points;
  the pre-fix default-light captures measure about 48 points. It requires a
  loaded, unscrolled Codex fixture, not an arbitrary screenshot. Use one theme
  per invocation; a missing surface error names `--theme` so a mismatched flag
  is not confused with an unloaded fixture. The six local-only helper tests
  verify both scales/themes, inclusive bounds and fail-closed behavior against
  generated images. They validate the algorithm, not the app layout, and stay
  outside automatic CI discovery. UI journeys separately cover navigation,
  other cards and layout choices.

- `GreptileAllowanceUITests.testReviewHistoryAndBillingAvailabilityStates`
  runs the production Greptile transport/parser against an intercepted synthetic
  endpoint. It captures review-history-only dashboard, review statuses and
  account metrics, then checks empty activity, an explicit hypothetical returned
  review quota, and HTTP failure. Missing billing data never becomes a zero
  credit balance or an assumed Free allowance. Run locally with
  `-only-testing:CodexBarIOSUITests/GreptileAllowanceUITests`. Every non-fixture
  network request is blocked.

- `CodexCreditsPoolUITests.testThirtyDayWindowLabelAndSavedVisibility`
  feeds a synthetic Free account's 2,592,000-second window through the real
  Codex parser. It captures "30-day usage limit" on the dashboard, Settings,
  and Customize Card, checks the reported 12% usage, and verifies saved hiding
  after relaunch. Run locally with
  `-only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testThirtyDayWindowLabelAndSavedVisibility`.
  It never contacts OpenAI.

- `CodexCreditsPoolUITests.testOptInBalanceStatesAndSavedAccountChoices`
  uses isolated synthetic Codex accounts through the production parser. It
  checks the off-by-default Settings switch, 62,500 credits, zero, unavailable,
  unlimited and failed-refresh states, Customize Card synchronization, relaunch,
  restoration and two-account isolation at accessibility text size. Screenshots
  cover Settings and the dashboard. Run locally with
  `-only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests`; it never contacts OpenAI.

- `ClaudeUsageUITests.testWindowLabelsAndSavedCustomizationForProAndMax`
  uses synthetic Pro and Max 20x responses through the real Claude parser. It
  captures both "5-hour" and "Weekly" with percentages and resets on the
  dashboard, checks the same labels in Customize Card, and verifies a hidden
  weekly metric stays hidden after relaunch. It never contacts Anthropic.
  Run this journey locally with `-only-testing:CodexBarIOSUITests/ClaudeUsageUITests`.

- `testAccountSetupPersistsGroupAndCredentialAtAccessibilitySize` starts with
  no accounts or groups, adds a group through Settings, opens Add Account,
  chooses OpenRouter, selects its group, and saves a synthetic key.
  It checks the dashboard balance, terminates and relaunches the app in the
  same namespace, then reopens Settings and checks the saved label, selected
  group, and credential availability.
- `testRefreshRecoveryHistoryAndAccountDeepLink` starts with a synthetic
  account and history. It checks a fresh $25 balance, taps Refresh, checks that
  the failed fetch preserves a stale $25 balance, reads the error, and retries
  to obtain a fresh $60 balance. It opens History, selects Today and 7 days,
  checks that the chart's accessible value changes, then delivers an actual
  `codexbar://provider?account=ui-navigation-5` URL while History is open.
  Five additional accounts put this distinct destination outside the viewport.
  Without helper scrolling, the dashboard must dismiss History and reveal the
  requested account. A second URL returns to the recovered account and verifies
  its fresh $60 balance remains intact.

- `testSixGoogleChoicesAndIndependentCustomizationPersist` starts with one
  Gemini account containing both source connections. Apps reads 12% and 45%
  used; coding reads 0%, 31%, 0%, and 0%. Each coding metric must expose its
  reset caption on the dashboard. It reaches all six settings switches
  in that account, moves, resizes, restyles and hides Gemini Models weekly
  independently, then relaunches and restores that choice through Customize Card.
  It retains a screenshot of the restored, selected ring menu.
- `testTwoCodexAccountsKeepSeparateUsageAfterRelaunch` uses two synthetic
  ChatGPT identities with separate saved credentials and different usage. It
  captures the account list, Add Account provider picker, the normal/private
  browser choices for another Codex account, and distinct cards after relaunch.
  It never contacts ChatGPT or proves Google accepted a live sign-in.
- `testSavedGeminiRingIsSelectedInVisualizationMenu` changes Gemini Models weekly
  to a ring, relaunches, and verifies the Visualization menu marks the saved
  style as selected. It retains a screenshot of the selected menu.
- `testGeminiOnlyDashboardShowsCodingSetupAndKeepsSelectionOnRelaunch` starts
  with only Gemini Apps connected. All four coding choices stay visible with
  Setup required in the same Gemini card. It hides a coding metric, refreshes,
  relaunches, then restores the selection in that Gemini account's settings.
- `testCodingOnlyGeminiChoicesSurvivePartialAndFailedRefresh` runs a Gemini
  account with only coding connected. Its Apps choices show Setup required.
  A partial refresh makes one coding quota unavailable and another disabled,
  while both remain in Customize Card. A subsequent failure preserves stale
  values; recovery displays 100%, 31%, 20%, and 60% used with fresh status.
  All six settings switches remain reachable after recovery.

- `testGitHubBillingPermissionDisclosure` opens a synthetic personal account,
  checks the write-capable `user` scope disclosure and sign-in-again guidance,
  and retains screenshots. It never opens live authorization or sends fixture
  tokens to GitHub. Run just this manual journey with:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarIOSUITests \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:CodexBarIOSUITests/AccountJourneysUITests/testGitHubBillingPermissionDisclosure \
    -resultBundlePath build/github-billing-permissions.xcresult test
  ```

- `testGitHubBillingProductSummaryAndRoutinePlacement` checks product summaries
  and routine usage placement on the billing card.
- `testGitHubBillingActionableWarningStaysInline` checks that an actionable
  warning remains visible on the billing card.
- `testGitHubBillingAllowanceStates` covers the synthetic billing allowance states.
- `OpenCodeSignInUITests.testDisconnectedAccountOffersGuidedSignIn` exercises
  setup, canceled approval, workspace choice, removal, reconnect, and relaunch.
  Browser approval is synthetic, with no live provider account or credentials.
- `OpenCodeSignInUITests.testVerificationFailureKeepsAccountDisconnectedAndAllowsRetry`
  verifies that failed usage validation does not save a connection and permits
  another attempt or cancellation. It also runs the production Console transport
  through offline Go renewal, cancellation, payment recovery and foreign-subscriber
  fixtures. Light/default and dark/accessibility2 captures cover the dashboard,
  billing details and the default-on renewal setting, including saved hiding.
  Run just this existing manual journey with
  `-only-testing:CodexBarIOSUITests/OpenCodeSignInUITests/testVerificationFailureKeepsAccountDisconnectedAndAllowsRetry`.
  It adds no automatic CI work or additional release journey. See [OpenCode sign-in](OPENCODE-SIGN-IN.md)
  for local auth transport and quota regressions.
- `GrokSignInUITests` exercises Grok's Add Account entry, synthetic approval,
  cancellation, reconnect and removal. A second journey shows the shared Grok
  meter beside Cursor's separate Grok Bot meter, a verified paid weekly period
  whose omitted usage shows 0%, an explicit-null percentage that remains
  unavailable, and a no-allowance state.
  Neither journey authorizes a real account or contacts xAI. On iPadOS versions
  that do not expose context-menu actions to XCTest, the More Information
  relaunch hook targets only the Grok account using
  `CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT=ui-grok-connected`.
  A separate local-only journey checks credits-only and already-saved
  credits-first layouts, relaunch persistence, fresh order, 0% and unavailable
  weeks, and an explicit credits-first reorder on iPhone and iPad.

- `GrokSignInUITests.testCursorStaleSignInReconnectCancellationAndValidZero`
  checks a lifetime-ended synthetic session through the real Cursor provider,
  retained stale values, no-prior-data unavailability and fresh zero with a
  Bot-only rejection. It drives the normal Settings sign-in controller with
  a simulator-only authorization replacement, including account selection,
  cancellation without sign-out and successful return. Light/default and
  dark/accessibility-size-2 captures use isolated credentials, not a live
  browser or account. Run locally with
  `-only-testing:CodexBarIOSUITests/GrokSignInUITests/testCursorStaleSignInReconnectCancellationAndValidZero`.
  This journey is manual/release-only; automatic native test counts stay unchanged.

- `GrokSignInUITests.testCursorFreshPercentagesBotAndSavedChoices` drives the
  real Cursor request builder, transport and parser against a network-blocked
  synthetic replay. Its cache-aware loader returns old zeros for the previous
  request policy and fresh fractional Cursor usage plus 3% Other Models for a
  reload. A valid Bot response takes 2.5 seconds, beyond the old two-second
  deadline. The journey checks 1%/3%, weekly Bot data, details, all four choices,
  saved ring/width/hide/show, failed-refresh retention and a forbidden Bot
  response on iPhone and iPad. This replay proves request-policy and deadline
  handling, not that the affected live response was cached. No account cookies,
  tokens or outbound provider networking are used. It is manual/release-only.

- `SettingsEvidenceUITests.testSettingsDismissalSignalRejectsTheBackgroundGear`
  verifies that a gear exposed behind the Settings sheet does not count as a
  closed sheet, then checks that Done returns to a hittable dashboard gear.
  Settings journeys wait for this actual dismissal before reopening. The
  Gemini-only journey uses the existing explicit menu/customizer transition
  checks instead of trying to scroll to a missing menu item. All 29 declared
  journeys must pass on each family; this added regression is manual/release-only.

- `SettingsEvidenceUITests.testEverySettingsDestinationAndDoneBack` captures
  root summaries and all six existing destinations, then checks Done/Back.
- `SettingsEvidenceUITests.testPendingDuplicateGroupBlocksDoneUntilCorrected`
  checks that a duplicate pending group blocks Done, then corrects the name
  and verifies both saved groups after closing and reopening Settings.
- `SettingsEvidenceUITests.testSyntheticGrantedAndDeniedNotificationFeedback`
  injects granted and denied authorization results for incident and recovery
  notifications, checks feedback and saved preferences across closing/reopening,
  then disables monitoring and verifies the controls are disabled.

Local-only Foundation regressions cover exact destination mapping, summary
formatting, independent UUID requests, denial, cancellation, superseded and
repeated completions, separate view state, and updates to the latest preferences:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter SettingsPresentationRegressionTests
```

The tests assert accessible names, values, selection state, and reachable tap
targets. They cover app-owned account and usage navigation. Live website sign-in,
provider API contracts, and VoiceOver speech remain separate verification.

## Claude window-label regressions

Run the local-only parser and downstream-identity coverage with synthetic Pro
and Max 20x data:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter ClaudeWindowLabelTests
```

These regressions cover legacy, structured, and unified-header windows,
`seven_day_oauth_apps`, idle and scoped sessions, percentages and reset times,
saved metric layouts, history, alert identity, widget tile IDs, and Watch
snapshots. They do not add tests to either automatic unit suite or establish
live provider results.

## Claude saved-reset regressions

The same manual Claude journey covers two-account availability, irreversible
confirmation and cancellation, successful refresh, unchanged second-account
usage, relaunch persistence and ambiguous-request protection. An open confirmation
expires automatically without a reset request. The dashboard remains open across
grant start/expiry boundaries and updates without another interaction. Provider
cooldown text and the disabled action change when the cooldown ends, with zero
requests. It exercises
light/dark with default/accessibility2 text, plus zero, ineligible, paused,
inactive, expired, unknown, malformed and failed inventories. Fixtures use the
production inventory parser and an isolated fake consuming provider; networking
is blocked and no Anthropic reset is used. The original base phase remains 29 journeys.

Local/native regression classes are `ClaudeUsageResetInventoryTests`,
`ClaudeUsageResetClientTests`, `ClaudeUsageResetFlowTests` and
`ClaudeUsageResetProviderTests`. They check account/organization/credential
isolation, exact confirmed-grant comparison across refreshed caches, confirmed and ambiguous response handling,
receipt-write failure, redirects and stale completions. These native tests run
locally or on explicit manual dispatch, never automatically for ordinary PRs.

## Claude Fable regressions

The existing manual Claude journey checks a provider-returned Fable allowance
separately from the shared 5-hour and all-model weekly windows. It covers two
accounts, hide/restore and model-name changes across relaunch, Customize Card,
light/dark appearance and default/accessibility2 text. Absent allowances and
usage-credit-only responses do not create a Fable quota. The release count stays
29 original journeys per family. The full release also requires the supplemental and commerce phases above. No live provider quota is consumed.

`ClaudeFableWeeklyTests` runs locally and in the manual native unit suite. Its
nine cases cover reported values, known aliases, inactive/duplicate windows,
missing/credit-only data, account/credential isolation, persisted older choices,
daily history, saved widget tiles and watch complication selections.

## GitHub Billing API fixtures

The separate manual fixture harness exercises personal Free and Pro allowances,
public and private repository classification, mixed Actions runners, accrued
storage, Git LFS, discounts, organization budgets and pagination, missing and
malformed fields, and distinct 401, 403, 404, 429, and 5xx handling. It also
checks that the real authorization URL requests `user` for personal billing,
that a modeled permission boundary rejects the former `read:user` grant, and
that failure diagnostics exclude raw payloads, owners and arbitrary headers.
These tests do not establish live OAuth compatibility:


```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run GitHubBillingFixtureTests
```

It uses only synthetic payloads and an in-process URL protocol. It makes no live
GitHub requests and uses no account credentials. The manual `workflow_dispatch`
iPhone worker runs this harness before its journeys;
routine pull-request CI does not add this work.

## Fixture startup and isolation

The DEBUG app accepts `CODEXBAR_UI_TESTS=1` only on a simulator, with a valid
UUID in `CODEXBAR_UI_TEST_RUN_ID`. Invalid IDs fail immediately. This creates
`com.hemsoft.CodexBarIOS.ui-tests.<UUID>`, never an arbitrary defaults domain.
`CODEXBAR_UI_TEST_RESET=1` clears only that namespace; `0` preserves it for
relaunch. `CODEXBAR_UI_TEST_SCENARIO=empty` begins with no accounts, while
`recovery` seeds a recovery account, five navigation accounts, and three history
samples per account. Only the recovery account fails its first refresh; the
navigation accounts retain a distinct $90 balance. The `google-six`, `google-apps-only`, and `google-coding-only` scenarios each
seed one Gemini account with both sources, Apps only, or coding only. Test runs generate their
own UUIDs, so separate tests and devices cannot reuse each other's state.

The fixture supplies this suite to account configuration, history, app review,
app updates, GitHub preferences, and widget preferences. Its credential store
uses the same suite and accepts only fixed synthetic test credentials. It never
reads or writes Keychain. Only synthetic OpenRouter, Claude, Codex, combined Gemini, GitHub Billing, Grok and Cursor
usage providers are registered. The production account form, group
persistence, refresh service, dashboard, History, and URL handler still execute.

The fixture disables lifecycle polling and bootstrap imports. Its notifier
never delivers notifications and denies authorization by default; the explicit
simulator-only `CODEXBAR_UI_TEST_NOTIFICATION_GRANTED=1` flag supplies a synthetic
grant for Settings evidence. Widget publishers and the Watch sender do nothing. A URLProtocol blocks unexpected URLSession traffic. No credentials,
provider account, Watch pairing, notification permission, or external network
service is needed. DEBUG fixture functions have an explicit exclusion in the
function-risk policy because they are test infrastructure. The production risk
baseline remains unchanged.

## CI and failure reproduction

Ordinary PRs run pinned lint and lightweight configuration checks. The `iOS tests`
status runs unit tests, coverage and function risk only through an explicit dispatch.
Native validation and UI journeys run before releases or on demand; ordinary pull
requests do not require a manual full run. Before a release, dispatch the `CI`
workflow against the exact release-candidate branch or tag. After the five
quality jobs pass, `Full iOS UI validation` runs both device families. The
release cannot proceed unless every job passes for the candidate SHA. If that
SHA changes, dispatch a new run.

Each family runs six independent manual shards: three original-journey partitions,
supplemental, synthetic commerce, and native commerce. The original 29 tests are
balanced using retained hosted durations into groups of 8, 8 and 13. Every shard
keeps the 90-minute limit, pinned Xcode 26.6 / 17F113 and iOS 26.2 / 23C54,
and provisions its own simulator. Fail-fast remains disabled.

Native preparation, purchase/restore, purchase-error preparation, purchase-error
and the final normal StoreKit reset stay sequential on one worker. The reset is
attempted even after a journey failure. The two SUS evidence journeys are included
in the supplemental eight, so the full gate covers 53 distinct journeys per
family plus the three preparation/reset calls. Marketing capture remains excluded.
The original local runner retains its separate 29-pass contract.

The always-run aggregate requires all twelve workers to succeed and validates their
compact proofs against the checked-out SHA and source fingerprint. Missing,
duplicate, stale, wrong-runtime or substituted-test proofs fail the gate. Every
phase still requires zero skips or expected failures. Full results, logs and
exported failure screenshots remain available for 14 days, separate from the small
proof artifacts used by the aggregate. See [CI-POLICY.md](CI-POLICY.md) for dispatch
and SHA-verification commands.

Reproduce one shard from a clean committed checkout on air:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
  python3 scripts/ui_release_shards.py run --family iphone --shard original-1 \
  --output /tmp/codexbar-ui-original-1
```

Choose any shard listed in [the shard plan](scripts/ui-release-shards.json), and a
new output directory for each invocation. The command shuts down only its owned
simulator. It does not launch provider sign-in or touch live account storage.

To reproduce a failure, rerun the same family with the command above. Every
journey resets its own storage, so no simulator-wide data wipe is needed.
For a navigation mutation check, make a disposable copy of the repository,
replace the `dismiss()` call inside `AddAccountSetupFlow`'s Done button with an
empty action, and run the iPhone suite there. The setup journey must fail when
it cannot reach the dashboard balance. Keep that mutation out of the PR.

### Widget reset-caption layout check

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/tests/widget-reset-layout-tests.sh`.
The on-demand/release SwiftPM smoke CI job runs the same check. It compiles the production
widget tile and its dependencies against the SwiftPM module on macOS, adapting
only the platform background color. ImageRenderer measures 54 fixtures across
all visualization styles, three tile widths, reset/warning captions, and missing
captions. Each tile must fit within 105 points, reserving space for the medium
widget's margins, spacing, and Updated footer. This is an intrinsic-layout
regression check, not an iOS screenshot or full WidgetKit host test.

For Gemini Models and Other Models fixtures, add small and medium widgets using
Automatic display mode. At ordinary usage, verify that the reset countdown and
local reset time appear below the metric heading; at warning pace, verify that
the projection warning takes precedence. Rings, dials, and large numeric
visualizations sit beside the heading instead of taking a separate row above
the caption. In medium widgets, check that the Updated footer also remains
visible with those saved visualization choices. Captions may wrap to two lines and scale
down to fit the tile. Check a long account label and a weekly caption in both
widget sizes. Other providers retain their existing caption content, now also
visible in Automatic mode. Missing descriptions add no empty caption row.

The manual-only `CodexCreditsPoolUITests.testPreciseSubscriptionPillsOnExpandedAndCollapsedCards`
checks Codex Pro/Plus, Claude Max 5x, verified Grok, unknown Google and API-credit
headers in light/dark at default and accessibility text sizes. It asserts actual
expanded/collapsed state changes and the same account's plan after refresh. The
base runner requires all 29 original journeys with zero skips; ordinary automatic
CI does not run them.

## Google and OpenCode subscription headers

The existing manual-only compact-header journey also exercises isolated
`google-plan-*` scenarios for named Google AI Free, Plus, Pro, generic Ultra,
Ultra 5x/20x and unknown metadata. Each scenario seeds an OpenCode Go + Zen
card. It verifies Google labels, omitted OpenCode pills and expanded/collapsed
cards in light/default and dark/accessibility text sizes, retaining screenshots.
These are synthetic responses, not a live account comparison.

Run the affected journey with
`-only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testCompactCardHeadersAndIndependentControls`
on the UI-test scheme. This extends an existing journey; the release runner's
29-test contract and automatic CI workloads are unchanged.


## Subscription billing countdowns

The existing compact-header journey also exercises renewal pills in light/default
and dark/Accessibility 2 text, exact billing details, two accounts, a long Google
plan label, OpenCode without a plan pill, unknown/canceled/stale/passed dates, and
the default-on preference with immediate changes and relaunch persistence.

For focused local issue validation, build the test products, then set the
selector in a copy of Xcode's generated test-run specification. Do not rely on
`TEST_RUNNER_` shell forwarding: the installed runner may omit that value.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexBarIOS.xcodeproj -scheme CodexBarIOSUITests \
  -destination 'platform=iOS Simulator,id=<discovered-iphone-or-ipad-id>' \
  -derivedDataPath .build/renewal-ui -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO build-for-testing

python3 - <<'PYTHON'
from pathlib import Path
import plistlib
products = Path('.build/renewal-ui/Build/Products')
source = max(products.glob('CodexBarIOSUITests_*.xctestrun'), key=lambda path: path.stat().st_mtime)
run = plistlib.loads(source.read_bytes())
run['CodexBarIOSUITests'].setdefault('EnvironmentVariables', {})['CODEXBAR_UI_TEST_SUBJOURNEY'] = 'renewals'
(products / 'subscription-renewals.xctestrun').write_bytes(plistlib.dumps(run))
PYTHON

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -xctestrun .build/renewal-ui/Build/Products/subscription-renewals.xctestrun \
  -destination 'platform=iOS Simulator,id=<discovered-iphone-or-ipad-id>' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testCompactCardHeadersAndIndependentControls \
  test-without-building
```

The renewal subjourney also checks parsed Google AI Free has no renewal label or
billing-only More Information menu item. The release runner does not set this
selector and still requires all 29 original journeys on both families, followed
by the required supplemental and commerce phases. Billing
fixtures are synthetic; real-account billing comparisons remain Franz-owned.
The same focused journey covers Claude and Grok renewal pills and unknown,
canceled, stale and passed details. Its billing connection sheet uses the real
account-verifying client against a simulator-only URLProtocol: another sample
account is rejected, the matching sample account returns automatically, and
Disconnect Billing and Cancel preserve the usage connection. No live sign-in or
provider endpoint is accessed by that fixture.
See [subscription source coverage](SUBSCRIPTION-RENEWALS.md).

The renewal subjourney also opens Claude billing settings directly from unavailable
More Information before exercising account mismatch, reload, matching return,
disconnect and cancellation. Claude fixtures omit the unused legacy aliases.

Set `CODEXBAR_UI_TEST_SUBJOURNEY` to `billing` in the copied xctestrun file to
run only the guided billing recovery checks while diagnosing a connection flow.
Use `renewals` for complete renewal-focused validation on both device families.
