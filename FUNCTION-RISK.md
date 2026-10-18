# Function coverage and risk

The manual `iOS tests` and `watchOS tests` CI jobs collect coverage and run
`scripts/function-risk/measure.py`. A measurement error or failed baseline
comparison fails the corresponding manual quality status. Both statuses must
pass for an exact release candidate or a requested full validation run; they
are not ordinary pull-request merge gates. Both jobs publish artifacts named
`function-risk-ios` and `function-risk-watch`, including raw xccov coverage,
SwiftLint output, source declarations, the full JSON report and a Markdown review
queue. Artifacts remain available for 14 days. A collection failure produces
`failure.txt`; absent artifacts after collection was attempted also fail the
upload step. If a test suite fails before collection, the job preserves its
xcresult diagnostics and skips the risk upload.

## Measurement contract

Tools are pinned in `scripts/function-risk/policy.json`: Xcode 26.6 build 17F113
provides the compiler, SwiftSyntax parser and xccov; SwiftLint 0.65.1 comes from
the existing exact SwiftLintPlugins dependency and its checksum-verified binary.
Python 3.9 or later uses only the standard library. Changing the Xcode or
SwiftLint pin requires reviewing the baseline and recording the evidence below.
An unexpected tool version fails collection.

The score is `CRAP = CC^2 * (1 - coverage)^3 + CC`. Coverage is each function's
`coveredLines / executableLines` from `xccov view --report --json`, never a
file, target or repository average. Xccov exposes executable-line coverage,
not branch coverage. This cannot establish that both outcomes of a condition
were tested when they share a covered line. Switch to branch coverage only with
a reviewed tool/baseline migration.

`CC` preserves the issue #306 audit's **SwiftLint decision count**, which starts
at zero. It is not the conventional McCabe count that starts at one. The pinned
[SwiftLint rule](https://github.com/realm/SwiftLint/blob/0.65.1/Source/SwiftLintBuiltInRules/Rules/Metrics/CyclomaticComplexityRule.swift)
counts `if`, `guard`, loops, `catch` and switch cases, subtracts fallthroughs,
and measures functions and initializers. It excludes nested declarations from
the enclosing function's count and includes closure decisions in that function.
A separate measurement configuration reports even zero-decision declarations;
it does not change the strict lint thresholds used to check source style.

The tool parses every production source root with the selected Xcode's
SwiftSyntax, then reads production membership from the project's Sources build
phases. It joins each declaration's header span to one xccov function and the
exact SwiftLint line/column. Missing or ambiguous joins remain unmatched.
Signatures use syntax tokens and type scope, so formatting and line shifts do
not change baseline identity. Repeated signatures use their source-order
alternative number. Renames and removals require explicit baseline review.

Each report keeps its platform and selected coverage target. The iOS suite
uses `CodexBarIOS.app` and `CodexBarIOSWidget.appex`; the watch suite uses
`CodexBarWatch.app` and `CodexBarWatchWidget.appex`. When source is compiled into
both app and widget, the app owns its score. The other copy's coverage remains
in the inventory. We never choose whichever target has higher coverage or
combine iOS and watch counters. Incidental embedded products in another
platform's result remain listed with a reason.

## Gate and review queue

- New production declarations above 30 fail. Existing production declarations
  above 30 may not exceed their explicit baseline ceiling.
- Score comparisons use exact rational arithmetic from integer counts. Rounding
  to four decimals happens only in the Markdown display.
- Scores 15 through 30 form a review queue in the report. A score of exactly 30
  is allowed; exactly 15 enters the queue.
- Unmatched production declarations fail unless an individual baseline entry
  explains the instrumentation gap and matches both source hash and complexity.
  Changed code must not inherit an exception. Resolved exceptions must be removed.
- Missing targets, empty target coverage, missing complexity, malformed measured
  line counts, missing production source roots, or stale high-risk identities
  fail collection or the gate. A removed high-risk declaration requires a
  reviewed baseline edit, even if the removal is an improvement.

Accessors, stored-property initialization, standalone closures and synthesized
or generated symbols have no independent SwiftLint func/init complexity. The
report lists their coverage with a reason and assigns no artificial score.
An unjoined coverage symbol also remains visible. These are measurement limits,
not claims that the code is covered. Files with no func/init bodies are listed.
There is no whole-app coverage percentage target.

Screenshot exclusions are explicit in `policy.json`: the DEBUG-only fixture
file and the exact screenshot scene-routing declaration. Their available
measurements remain visible. Normal UI, authentication, widget and platform code
are production code. The only initial unmatched exceptions are the two
non-iOS `#else` fallback bodies in `WatchSnapshotCoordinator.swift`. Their
hashes lock the currently uncompiled source; neither receives a coverage score.

## Reproduce

Use a clean committed checkout and new output directories. The release pin is
Xcode 26.6 / 17F113, iOS SDK/runtime 26.5 and watchOS SDK/runtime 26.5. The runner
also checks iOS runtime build 23F77, observed in the retained issue #468 26.5
preparation result. It does not substitute a newer runtime. Xcode 27.1 runs with
`--supplementary` are development evidence and cannot qualify this release.

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
risk_run="$(mktemp -d /tmp/codexbar-risk.XXXXXX)"
python3 scripts/verify-release-toolchain.py --output "$risk_run/toolchain.json"
python3 -m unittest discover -s scripts/tests -p 'test_function_risk.py' -v
python3 -m unittest discover -s scripts/tests -p 'test_pro_release_validation.py' -v
python3 scripts/function-risk/prove-coverage-union.py --output "$risk_run/union-proof"
./scripts/run-pro-release-validation.sh native --output "$risk_run/native"
python3 scripts/function-risk/measure.py --platform ios \
  --inputs "$risk_run/native/coverage-inputs.json" --output "$risk_run/ios-risk"
watch_device_id="$(./scripts/select-watch-simulator.sh)"
python3 scripts/verify-release-toolchain.py --watch-device "$watch_device_id" \
  --output "$risk_run/watch-toolchain.json"
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarWatchTests \
  -skipPackagePluginValidation \
  -destination "platform=watchOS Simulator,id=$watch_device_id" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -enableCodeCoverage YES -resultBundlePath "$risk_run/watch.xcresult" \
  CODE_SIGNING_ALLOWED=NO test
python3 scripts/function-risk/measure.py --platform watch \
  --result "$risk_run/watch.xcresult" --output "$risk_run/watch-risk"
```

The native command creates its own simulator and fresh instrumented DerivedData.
It runs the full ordinary iOS suite, including 197 shared Pro test methods from
22 sources, then four separately selected native phases: preparation 1, native
commerce 25, Germany preparation 1 and Germany storefront 1. The two top-level
`testProClock` and `testProAnchor` support functions are not XCTest methods.
Every native invocation uses the isolated Debug host and ad hoc signing. The
five complete result bundles are required for aggregate iOS measurement.
Preparation and its consumer must use the same build and owned simulator.

The collector exports each xcresult's actual `.xccovreport`/`.xccovarchive`
pair and passes all five pairs to `xccov merge`. It reads function counts from
the merged report; it never sums or takes the maximum of covered-line counts.
It rejects duplicate targets/files/functions, incompatible denominators, stale
source paths, missing phases, changed receipts, filtered ordinary test runs,
failed or skipped tests and empty app counters. Source hashes, tool versions,
actual runtime, built binaries, discovered/executed test identities and raw
input/merged artifacts remain in the output. UI counters are not included in
the earlier iOS risk job. Watch collection keeps its single-result interface
and verifies watchOS execution. A legacy single-result receipt is explicitly
marked as lacking producer provenance.

`prove-coverage-union.py` creates a tiny hostless macOS XCTest project outside
the checkout and executes opposite branches in two separately built result
bundles. It requires the merged shared function to cover more lines than either
input, fewer than their sum, and the full denominator. It also requires retention
of ordinary-only and native-only functions. This proves xccov merge semantics
when it passes; it does not qualify application coverage or native StoreKit.
The default requires the pinned Xcode. Local `--supplementary` output remains
unqualified. Keep the first failure and use a new output directory for a repair.

The bounded Python fixtures exercise PBX `SOURCE_ROOT` and group-relative paths,
missing/ambiguous roots, raw pair export, provenance, omitted phases, duplicates,
empty counters and incompatible denominators. Existing six-decision uncovered
risk and exact-ceiling fixtures still fail and pass at their original boundaries.
No risk arithmetic, baseline, exception or ceiling changes are part of #470.

## Initial baseline and bounded risk plan

Issue [#306](https://github.com/HemSoft/codexbar-ios/issues/306), source revision
`78b6a213c53ae4a90e61cd4802d31aafbeb91e35`, measured September 5, 2026. Both suites
passed, with 654 iOS and 59 watch tests and no failures or skips. The inventory
has 1,182 scored iOS declarations, 2 unmatched iOS fallbacks and 7 screenshot
exclusions; watch has 101 scored declarations and no unmatched declarations.
These are platform-specific counts, so shared source can appear in both.

The initial ceilings below are captured as exact line counts and decision
counts in `scripts/function-risk/baseline.json`. Six production functions
exceeded 30 in the initial baseline. The measurement gate alone did not fix
them. Before the next production release, handle the following four bounded work
items through the repository's issue-first workflow, starting with sign-in and
pagination. Review the remaining ceilings in each item and lower or remove
entries only after fresh coverage proves the improvement.

| Work item | Existing functions | Initial CRAP | Completion evidence |
| --- | --- | ---: | --- |
| Gemini sign-in session state | `GeminiBrowserSignInSession.inspectSession()` | 56 | Test signed-out, missing-cookie, loading, validated and failed-session paths through an injectable state boundary; reduce score to at most 30. |
| Greptile pagination | `GreptileUsageProvider.fetchUsage(for:)` | 30.721360 | Exercise remaining early exit and pagination failure paths; preserve incomplete-scan behavior and reduce score to at most 30. |
| Dashboard metric dispatch | `ProviderUsageCard.metricTile(_:)` | 156 | Extract/test metric selection and presentation decisions without screenshot automation; reduce each resulting function to at most 30. |
| Settings dispatch and notifications | `SettingsView.summary(for:)`, `settingsDestinationView(_:)`, `updateGitHubStatusNotificationSetting(isEnabled:recovery:)` | 42, 42, 56 | Test destination mapping and notification permission outcomes; reduce each function to at most 30. |

Baseline edits must include the source revision, tool versions, fresh reports,
changed counts and a concrete reason in the PR and this document. Do not
regenerate the baseline in CI. Reviewers must distinguish a verified reduction,
a renamed or removed function, a tool migration and an attempted increase. A
new production risk requires remediation, not a routine baseline addition.

## Gemini session-state remediation

Issue [#374](https://github.com/HemSoft/codexbar-ios/issues/374) extracts cookie-read
eligibility and outcomes into a state model without changing the guided browser,
Google cookie policy, provider verification, or account-scoped persistence.

The before report is the `function-risk-ios` artifact from
[run 36637347373](https://github.com/HemSoft/codexbar-ios/actions/runs/36637347373),
source `bd5cac53a87e72d8432720d49b1903a9212c490f`. The fresh after report is the same
artifact from [run 36645924629](https://github.com/HemSoft/codexbar-ios/actions/runs/36645924629),
PR source `78262fae2c96c616961e4c606248e983ca6ec028`. Actions measured its merge
revision `2e43f4710b4e9a3ae83700a6d67e7a9424667a90`, whose parents are that source
and the unchanged default branch; its tree matches the PR source exactly.
Both reports use Xcode 26.6 build 17F113, Swift 6.3.3, and SwiftLint 0.65.1.
Both iOS suites pass all 711 tests with zero failures or skips.

| Declaration | Decisions | Covered / executable lines | CRAP |
| --- | ---: | ---: | ---: |
| `GeminiBrowserSignInSession.inspectSession()` before | 7 | 0 / 24 | 56 |
| `GeminiBrowserSignInSession.inspectSession()` after | 2 | 0 / 8 | 6 |
| `GeminiBrowserSignInSession.inspectionContext()` | 0 | 0 / 6 | 0 |
| `GeminiBrowserSignInSession.apply(_:)` | 5 | 0 / 14 | 30 |
| `GeminiBrowserInspectionContext.canInspect()` | 0 | 0 / 3 | 0 |
| `GeminiBrowserInspectionState.begin(in:)` | 1 | 0 / 5 | 2 |
| `GeminiBrowserInspectionState.complete(cookies:revision:in:)` | 3 | 0 / 10 | 12 |
| `GeminiBrowserInspectionState.action(for:at:)` | 1 | 0 / 4 | 2 |

The improvement is reduced decision complexity, not increased iOS coverage.
Nine explicit local SwiftPM regressions exercise the state model with synthetic
cookies. Those macOS tests are not mixed into the iOS coverage counts above and
are not live Google sign-in proof. Run them separately:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter GeminiBrowserInspectionTests
```

Remove only the resolved `inspectSession()` high-risk entry from the iOS
baseline. Its identity is preserved, so future scores above 30 now fail the
normal production threshold rather than inheriting the old ceiling of 56.
No other ceiling, unmatched exception, exclusion, tool pin, automatic test
suite, or CI workflow changes. The fresh report has no gate errors and only
the two unchanged, hash-locked non-iOS fallback exceptions documented above.
Final exact-candidate release validation remains in
[#373](https://github.com/HemSoft/codexbar-ios/issues/373).

## Greptile pagination remediation

Issue [#375](https://github.com/HemSoft/codexbar-ios/issues/375) removes a redundant
empty-page branch without changing scan completeness, deduplication, page and
offset limits, provider failures, cancellation, reported quotas and reset dates,
or account-scoped credentials and cached results.

An empty page has `nextOffset == offset`. If that reaches a known total, the
earlier total check already returns success or an incomplete-scan failure based
on the unique review count. Otherwise an empty page is a short page, since the
constructor clamps page size to at least one. The existing short-page rule
succeeds only for an unknown total and rejects an outstanding known total.
The removed branch therefore had no additional outcome.

The before report is `function-risk-ios` from
[main run 36650036897](https://github.com/HemSoft/codexbar-ios/actions/runs/36650036897),
source `7740d1de489b5c06560828a512f0ab831f197966`. The after report is the same
artifact from [run 36651946794](https://github.com/HemSoft/codexbar-ios/actions/runs/36651946794),
PR source `3cdd4557f7783f97e049ddf801257a71164a18f5`. Actions measured merge revision
`bb412f39042532fbf16150215529833ecca6d364`; its verified parents are that source
and the unchanged default branch, and its tree matches the source exactly.
Both reports use Xcode 26.6 build 17F113, Swift 6.3.3, and SwiftLint 0.65.1.
Both iOS suites pass 711 tests with zero failures or skips.

| Declaration | Decisions | Covered / executable lines | CRAP |
| --- | ---: | ---: | ---: |
| `GreptileUsageProvider.fetchUsage(for:)` before | 20 | 96 / 137 | 30.721359533288506 |
| `GreptileUsageProvider.fetchUsage(for:)` after | 18 | 96 / 129 | 23.423975247462486 |

The exact after score is `1862370/79507`. No production function was renamed,
added, or moved. The reduction removes duplicate decisions and executable lines;
it does not combine local macOS test coverage with the iOS report.

Thirteen explicit local synthetic HTTP regressions cover empty, short, and full
pages, unknown and reported zero totals, clamped page sizes, duplicate/truncated
pages, both scan limits, HTTP/parser/transport failures, actual task cancellation,
missing/unreadable credentials, reported quota/reset fields, independent account
credentials and counts, and preservation of each account's last complete result.
They use no live provider credentials or network fallback. Run them separately:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter GreptilePaginationRegressionTests
```

Remove only the resolved Greptile entry from the iOS high-risk baseline. Future
scores above 30 now fail the normal threshold instead of inheriting its old
ceiling. Other ceilings, fallback exceptions, exclusions, tool pins, automatic
test suites, and CI workflows are unchanged. The fresh iOS and watch reports
have no gate errors; the two hash-locked non-iOS fallbacks are unchanged.
Dashboard and Settings remediation are documented below. Final exact-candidate
release validation remains in [#373](https://github.com/HemSoft/codexbar-ios/issues/373).

## Dashboard metric-dispatch remediation

Issue [#376](https://github.com/HemSoft/codexbar-ios/issues/376) extracts a pure
`ProviderMetricTileContent` interface for selecting valid metric data and
supporting details. The original tile function keeps its identity, button/detail
action, common container, and accessibility modifiers. Bounded SwiftUI renderers
consume the resolved data without changing fonts, formats, layout, or existing
usage/reset/projection/severity/history decisions.

The before `function-risk-ios` report is from
[main run 36655524851](https://github.com/HemSoft/codexbar-ios/actions/runs/36655524851),
source `7925e6019e4410d778560f423f80cbc04565ca44`. The fresh after report is from
[run 36658247013](https://github.com/HemSoft/codexbar-ios/actions/runs/36658247013),
PR source `3c2cbc424caefab88e9b3af9cdf88e8a3c6b839d`. Its measured merge revision
`279f1b880aeac48539cc1899dd68297c90021913` has verified default/source parents and
the exact PR tree. Both reports use Xcode 26.6 build 17F113, Swift 6.3.3, and
SwiftLint 0.65.1; both iOS suites pass all 711 tests with zero failures or skips.

| Declaration | Decisions | Covered / executable lines | CRAP |
| --- | ---: | ---: | ---: |
| `ProviderUsageCard.metricTile(_:)` before | 9 | 0 / 74 | 90 |
| `ProviderUsageCard.metricTile(_:)` after | 0 | 0 / 23 | 0 |
| `ProviderUsageCard.metricTileContent(_:)` | 5 | 0 / 14 | 30 |
| `ProviderUsageCard.unavailableTileContent(label:reason:)` | 0 | 0 / 8 | 0 |
| `ProviderUsageCard.creditsTileContent(label:value:detail:)` | 1 | 0 / 18 | 2 |
| `ProviderUsageCard.monetaryTileContent(metric:detail:)` | 1 | 0 / 18 | 2 |
| `ProviderMetricTileContent.resolve(metric:result:isFullWidth:)` | 4 | 0 / 12 | 20 |
| `ProviderMetricTileContent.resolveUsageBar(index:result:)` | 1 | 0 / 4 | 2 |
| `ProviderMetricTileContent.resolveCredits(result:isFullWidth:)` | 1 | 0 / 7 | 2 |
| `ProviderMetricTileContent.resolveMonetary(index:result:isFullWidth:)` | 1 | 0 / 5 | 2 |

All nine affected/resulting declarations are scored with nonzero executable-line
denominators. None is moved to an unmeasured accessor or renamed to escape the
baseline. This is bounded decomposition with a testable data-selection interface,
not increased iOS unit coverage or a claim that every branch is covered. The
local macOS tests and manually exercised UI states are not mixed into the iOS
coverage or presented as live provider proof.

Thirteen explicit local regressions exercise raw over-limit/reset/projection
values, missing and reported zero credits, stale/current/partial-failure policy,
invalid indices, all monetary kinds and their original precision/identity,
full-width supporting details, unavailable reasons, and account isolation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter MetricTileContentRegressionTests
```

The UI evidence also uses explicitly launched mixed-metric scenes in the existing
DEBUG-only, UUID-isolated, network-blocked `UITestFixtures` infrastructure. That
file was already excluded as test infrastructure; no exclusion or policy changed,
and no production selection or rendering logic is placed there. Existing manual
UI journeys exercise saved order, width/style/visibility, relaunch and recovery.
Current-head media and commands are recorded in the PR's Validation section.

Remove only the resolved `metricTile(_:)` high-risk entry after this fresh proof.
Its future scores above 30 now fail the normal threshold instead of inheriting
the initial ceiling of 156. All other ceilings, fallback hashes, tool pins,
exclusions, automatic test suites and CI workflows remain unchanged. Both fresh
platform reports have no errors, with only the same two hash-locked non-iOS
fallbacks. Settings remediation is documented below. Final release checks remain
in [#373](https://github.com/HemSoft/codexbar-ios/issues/373).

## Settings dispatch and permission remediation

Issue [#377](https://github.com/HemSoft/codexbar-ios/issues/377) introduces typed
Settings data/preference/help routes with one immutable complete mapping inside
`SettingsContentRoute.resolve(_:)`. Bounded summary and SwiftUI dispatch retain
all six existing forms. Existing category summary formatters move unchanged.
A per-kind UUID coordinator rejects obsolete authorization results; valid results
still update the latest settings rather than a captured start snapshot.

The before report is from [main run 36666411389](https://github.com/HemSoft/codexbar-ios/actions/runs/36666411389),
source `5cca1be5ab2375b36ef6a9d4a15fa032a2087c04`. The fresh after report is from
[PR run 36676926106](https://github.com/HemSoft/codexbar-ios/actions/runs/36676926106),
head `1bb295ba0c0796d936f3ede76db285107de54b89`. The measured merge revision
`bd8e5ebfddc3b823fbcf0be19254d76d6abaa513` has the verified base/head parents and
exact source tree `e004a856aae30b0fae0c994a7d6493ddd984742f`. Both reports use
Xcode 26.6 build 17F113, Swift 6.3.3 and SwiftLint 0.65.1. Both iOS suites pass
all 711 native tests with zero failures or skips.

| Declaration | Decisions | Covered / executable lines | Exact CRAP |
| --- | ---: | ---: | ---: |
| `SettingsView.summary(for:)` before | 6 | 0 / 32 | 42/1 |
| `SettingsView.summary(for:)` after | 3 | 0 / 13 | 12/1 |
| `SettingsView.settingsDestinationView(_:)` before | 6 | 0 / 16 | 42/1 |
| `SettingsView.settingsDestinationView(_:)` after | 3 | 0 / 10 | 12/1 |
| `SettingsView.updateGitHubStatusNotificationSetting(isEnabled:recovery:)` before | 7 | 0 / 46 | 56/1 |
| `SettingsView.updateGitHubStatusNotificationSetting(isEnabled:recovery:)` after | 2 | 0 / 21 | 6/1 |
| `SettingsView.dataSummary(for:)` | 2 | 0 / 11 | 6/1 |
| `SettingsView.preferenceSummary(for:)` | 3 | 0 / 20 | 12/1 |
| `SettingsView.dataSettingsView(_:)` | 2 | 0 / 8 | 6/1 |
| `SettingsView.preferenceSettingsView(_:)` | 3 | 0 / 10 | 12/1 |
| `SettingsContentRoute.resolve(_:)` | 1 | 0 / 14 | 2/1 |
| `GitHubStatusNotificationPreference.updating(_:isEnabled:)` | 2 | 0 / 10 | 6/1 |
| `GitHubStatusNotificationAuthorization.isPending(_:)` | 0 | 0 / 3 | 0/1 |
| `GitHubStatusNotificationAuthorization.begin(_:)` | 0 | 0 / 5 | 0/1 |
| `GitHubStatusNotificationAuthorization.cancel(_:)` | 0 | 0 / 3 | 0/1 |
| `GitHubStatusNotificationAuthorization.cancelAll()` | 0 | 0 / 3 | 0/1 |
| `GitHubStatusNotificationAuthorization.complete(_:granted:)` | 1 | 0 / 5 | 2/1 |
| `GitHubStatusNotificationAuthorization.permissionMessage(granted:)` | 0 | 0 / 3 | 0/1 |
| `SettingsCategorySummary.accounts(accountCount:groupCount:)` relocated | 0 | 3 / 3 | 0/1 |
| `SettingsCategorySummary.dashboard(appearance:ordering:refreshInterval:historySamplingInterval:)` relocated | 0 | 4 / 4 | 0/1 |
| `SettingsCategorySummary.alerts(isEnabled:githubStatusEnabled:warningThreshold:criticalThreshold:)` relocated | 2 | 11 / 12 | 865/432 |
| `SettingsCategorySummary.help(installedVersion:availableVersion:)` relocated | 1 | 6 / 6 | 1/1 |
| `SettingsCategorySummary.count(_:singular:)` relocated | 0 | 3 / 3 | 0/1 |

All twenty resulting/relocated production functions score at most 12, with nonzero
executable-line denominators. The changed view functions and new pure interfaces
remain uncovered by native unit tests; this is a decision-complexity reduction,
not increased iOS coverage. No dispatch or permission decision is hidden in an
unmeasured accessor, renamed out of policy, or placed in fixture infrastructure.

Seventeen explicit local Foundation regressions cover complete routing, exact
summaries, separate notification kinds and view state, denial, cancellation,
superseded/repeated completions, and updates to the latest preferences:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter SettingsPresentationRegressionTests
```

Three additional manual-only UI journeys exercise the existing categories,
Done/Back and pending group validation, injected granted/denied authorization,
saved choices across closing/reopening Settings, and monitor-disable behavior on
both device families. This remediation raised the manual runner to nineteen
journeys. Issue [#384](https://github.com/HemSoft/codexbar-ios/issues/384) later
added the twentieth journey for Claude window labels, and
[#391](https://github.com/HemSoft/codexbar-ios/issues/391) adds the twenty-first
for Codex Credits pool. The zero-skip and exact-count gate remains strict.
Twelve credit parsing, transport and persistence regressions run only through
`xcrun swift test --filter CodexUsageTests`, not the automatic smoke executable. Automatic suites, jobs, triggers,
matrices, retries, destinations, timeouts and workflows are unchanged. Synthetic
media and macOS regressions are not native coverage or live permission proof.

Remove only the three resolved Settings baseline entries after this evidence.
Future production scores above 30 fail the normal threshold; no high-risk ceiling
remains on either platform. Original historical metadata, tool pins, exclusions
and both hash-locked non-iOS fallbacks are preserved. Both fresh platform reports
have zero errors. Final exact-candidate release validation remains separate in
[#373](https://github.com/HemSoft/codexbar-ios/issues/373).
