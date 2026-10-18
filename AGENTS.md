# CodexBar iOS Agent Notes

CodexBar for iOS is a native SwiftUI companion app (bundle ID
`com.hemsoft.CodexBarIOS`, scheme `CodexBarIOS`, Xcode project
`CodexBarIOS.xcodeproj`). Xcode targets: `CodexBarIOS` (app),
`CodexBarIOSWidget` (widget), `CodexBarIOSTests` (unit tests),
`CodexBarIOSUITests` (isolated iPhone and iPad UI tests),
`CodexBarWatch` (embedded watchOS 10 companion), `CodexBarWatchWidget`
(WidgetKit complication extension), and `CodexBarWatchTests` (watchOS unit
tests). Shared schemes are `CodexBarIOS`, `CodexBarIOSUITests`,
`CodexBarWatch`, and `CodexBarWatchTests`. `Package.swift` also exposes the
`CodexBarIOSSmokeTests` executable smoke harness. See
`README.md` for scope and the Windows reference repo, `APP-STORE.md` for store
metadata, `PRIVACY.md` for the privacy policy, `SUPPORT.md` for support flow,
and `CHANGELOG.md` for release history.

This file is a standing reference for agents working in this repo. Date-specific
facts (incident dates, snapshot UUIDs, certificate fingerprints) are noted as
such and may be stale — re-verify before relying on them.

## Contents

- [Required Issue-First Workflow](#required-issue-first-workflow)
- [Automatic CI Cost Ceiling](#automatic-ci-cost-ceiling)
- [End-User Experience and Live Verification](#end-user-experience-and-live-verification)
- [Changelog and Release History](#changelog-and-release-history)
- [Build and Test](#build-and-test)
- [Pull Request Reviewers](#pull-request-reviewers)
- [Connected iPhone and Signing](#connected-iphone-and-signing)
- [Browser Auth Takeaways](#browser-auth-takeaways)

## Required Issue-First Workflow

Every repository change must begin with a GitHub issue. This requirement applies
to code, documentation, configuration, build, and process changes, including
changes to this `AGENTS.md` file.

On intake of a repository-change request, create or identify its defining issue.
Unless the user explicitly requests same-turn implementation, end the turn after
that issue step; do not create a branch, edit files, run implementation tests,
open a pull request, or begin implementation in that same turn.

Before editing files:

1. Create or identify the GitHub issue that defines the change. If a request
   arrives without an existing issue, create one before making any edit.
2. Keep the `main` worktree clean and synchronize `main` with `origin/main`.
   Never make implementation changes directly on `main`, and never leave
   uncommitted implementation work there.
3. Create an issue-specific branch from the synchronized default branch and
   reference the issue in the branch and pull-request workflow.
4. Deliver the change through a pull request that links the issue and is the
   only path for returning the work to `main`.

## Automatic CI Cost Ceiling

Automatic pull-request CI runs only pinned SwiftLint and the existing lightweight
CI-policy assertions. CI does not run on `main` pushes. Native builds, unit tests,
function-risk analysis and the SwiftPM smoke harness run only before releases or
through explicit on-demand dispatch. Do not recreate retired automatic gates.
Automatic CI must not increase in elapsed time or summed billed runner time.
This is a hard constraint.

- Do not add automatic jobs, matrix entries, test destinations, retries,
  analysis passes, artifact processing, broader triggers, or longer timeouts.
- Do not add tests to a suite that automatic CI executes unless the same change
  removes at least as much automatic work and completed before-and-after runs
  prove that elapsed time and summed runner time do not increase.
- Put new costly validation in local developer commands or an explicit manual
  `workflow_dispatch` path.
- `Full iOS UI validation` is a release gate, not a pull-request gate. Do not
  dispatch it for routine PRs. Before a release, require a successful run for
  the exact release-candidate SHA; rerun it if that candidate changes.
- A pull request that changes automatic CI must list its trigger, job, matrix,
  retry, and timeout changes and provide completed before-and-after elapsed and
  summed runner-time measurements. Estimates do not satisfy this rule.
- If a proposed change cannot prove a non-increase, do not implement it in
  automatic CI.

## End-User Experience and Live Verification

Agents are responsible for delivering a good end-user experience. Routine
provider setup and reconnection must use a guided flow on the phone, such as
browser authorization with account selection and automatic return to the app.
Requiring users to import JSON files, export desktop sessions, copy cookies or
tokens, or enter OAuth client settings is not an acceptable setup experience.
Do not turn an integration shortcut into work for the end user.

Franz owns live provider-account testing and quota comparisons. Agents must
implement the requested experience, run relevant automated checks, and deliver
the build without waiting for Franz to prove access, sign in, supply screenshots,
import credentials, or verify live values. Mark those live checks as pending for
Franz; do not claim they passed or make them an agent delivery prerequisite.

This division of work does not remove automated validation or truthful runtime
status. Protect account isolation, save credentials securely, handle failed or
canceled authorization, and show only actual provider results. Resolve app-side
registration and configuration as development work. If required configuration
is unavailable, identify the exact missing item and continue independent work;
do not substitute a manual credential-import flow.

## Changelog and Release History

`CHANGELOG.md` is the source of truth for CodexBar release history. Maintaining
it is part of completing a change, not a cleanup task for the end of a release.
The history is used to prepare App Store **What's New** text, release notes,
support responses, launch announcements, and other marketing material, so it
must remain accurate, readable, and useful to people outside the codebase.

`CHANGELOG.md` follows a Keep a Changelog–style layout: a top-level heading per
version (`## <version> - <date>`), with `### Added`, `### Changed`, `### Fixed`,
and a separate `### Developer Experience` subsection for build, signing, and
release-process changes so they do not leak into App Store copy. Reference
GitHub issues with `([#NN](https://github.com/hemsoft-dev/codexbar-ios/issues/NN))`
when they add useful context.

- Update the current `Unreleased` version in the same branch or PR as every
  user-visible addition, change, fix, or removal.
- Describe the user benefit and observable behavior. Avoid implementation-only
  language in customer-facing sections.
- Keep development, build, signing, and release-process changes under the
  separate `Developer Experience` heading so they do not leak into App Store
  copy.
- Link the relevant GitHub issue when it provides useful context, and make sure
  the changelog never promises work that is only planned or still incomplete.
- Preserve published version sections as historical records. Do not rewrite or
  remove released entries except to correct a factual error.
- Before an App Store submission, replace `Unreleased` with the release date,
  verify the section matches the shipped `MARKETING_VERSION` (set in
  `CodexBarIOS.xcodeproj/project.pbxproj`), and derive the App Store and
  marketing copy from those verified entries.
- After cutting a release, start the next version's `Unreleased` section before
  additional product work lands. Do not reconstruct release history from git
  commits at the last minute.

## Build and Test

Use Xcode explicitly; the active `xcode-select` path may point at Command Line
Tools, so prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Build for the simulator (also boots, installs, and launches an iPhone 17
  simulator): `./run.sh`
- Plain simulator build without install/launch:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarIOS \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build
  ```

- Run unit tests (`CodexBarIOSTests`):

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarIOS \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test
  ```

- Run both isolated UI-test journeys on iPhone and iPad simulators:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-ui-tests.sh
  ```

  See [UI-TESTING.md](UI-TESTING.md) for fixture startup, storage isolation,
  single-family runs, and failure artifacts. Automatic pull-request CI does not
  run these journeys, and routine PRs do not require a manual full run. Before
  a release, dispatch the complete CI gate against the exact release-candidate
  branch or tag:

  ```sh
  gh workflow run ci.yml --repo hemsoft-dev/codexbar-ios \
    --ref <release-candidate-branch-or-tag>
  ```

  The release cannot proceed until all five quality jobs and manual
  `Full iOS UI validation` job pass for that exact SHA. Any change to the
  release candidate invalidates the result and requires a new manual run.

- Run the SwiftPM smoke harness:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift run \
    CodexBarIOSSmokeTests
  ```

- Run the canonical repository-wide lint gate with the exact
  `SwiftLintPlugins` version resolved by Swift Package Manager:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift package \
    plugin --allow-writing-to-package-directory swiftlint lint \
    --reporter xcode .
  ```

  The root `.swiftlint.yml` uses strict mode, so every warning fails this
  command. The same pinned build-tool plugin runs automatically for every
  Swift-producing iOS, watchOS, widget, test, and SwiftPM target. Xcode may ask
  developers to trust the package plugin on first use; unattended builds can
  pass `-skipPackagePluginValidation` after reviewing the pinned dependency.

- Build the watchOS 10 companion shell on a simulator compatible with the
  active Xcode toolchain. Run these commands from the repository root:

  ```sh
  set -euo pipefail
  watch_device_id="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./scripts/select-watch-simulator.sh)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarWatch \
    -destination "platform=watchOS Simulator,id=$watch_device_id" \
    build
  ```

- Run the watch foundation tests using the same compatible destination:

  ```sh
  set -euo pipefail
  watch_device_id="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./scripts/select-watch-simulator.sh)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarWatchTests \
    -destination "platform=watchOS Simulator,id=$watch_device_id" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    test
  ```

The selector chooses the newest installed watchOS runtime that is not newer
than the active `watchsimulator` SDK, then chooses a device reproducibly. If no
compatible device exists, it prints the active SDK plus the available runtimes
and devices before failing. The watch app is a dependent companion embedded in
`CodexBarIOS` and includes a WidgetKit complication extension driven by usage
snapshots from the iPhone. It does not enable independent installation,
credentials, or provider networking.

Function-level coverage and risk are required within the existing iOS and
watchOS test CI jobs. Run both suites with `-enableCodeCoverage YES` and separate
`-resultBundlePath` values, then run `scripts/function-risk/measure.py` for each
platform. See [FUNCTION-RISK.md](FUNCTION-RISK.md) for the pinned tools, exact
line-coverage basis, baseline policy, exclusions, failure fixtures, and complete
reproduction commands. New production CRAP scores above 30, increases above
existing high-risk ceilings, or unexplained measurement gaps fail the
corresponding required test status.

There is no separate typecheck tool beyond Xcode/Swift compiler warnings and
the test targets above.

## Pull Request Reviewers

Connected Codex is the sole required AI reviewer for this repository. Reuse an
existing automatic review when its completed result is tied to the current PR
head. Otherwise, request one review for that head through a PR comment:

```text
@codex review
```

Use the connected `HemSoft` GitHub account for requests and verify the effective
identity with `gh api user --jq .login`. Do not request Codex through the
Copilot `requestReviewsByLogin` API path.

Before declaring a PR ready:

- Require a completed clean Codex review for the current head SHA. A request,
  pending reaction, or review of an earlier head does not satisfy this gate.
  After meaningful updates, obtain fresh review evidence for the new head.
- Assess actionable findings already present from every source, including
  optional reviewers. Fix or disprove each finding with evidence and explicitly
  resolve addressed review threads in GitHub. An outdated unresolved thread
  remains unresolved.
- Do not request or wait for optional review products because an old roster,
  installed app, or automatic run lists them. Their availability does not add
  an AI-review gate.
- Re-check effective branch protection and repository rulesets. All required CI
  checks, human approval counts, code-owner approvals, and live change requests
  remain merge gates. A clean comment-only Codex review is sufficient for the
  AI-review gate when no formal approval is required; report its actual state
  without treating it as a formal GitHub approval.

SwiftLint is the sole required automatic PR status. Keep strict branch freshness
and current-head Codex review. Strict concurrency, iOS tests, watchOS tests and
SwiftPM smoke tests are manual-only alongside the complete release UI gate; do
not require their skipped PR statuses or dispatch full validation for routine
PRs. Retain all five quality workloads for an explicit release or on-demand run.
Report the actual current-head review and check state.

## Connected iPhone and Signing

Use [DEVICE-DEPLOYMENT.md](DEVICE-DEPLOYMENT.md) for the complete connected
iPhone build, install, launch, verification, and signing-recovery runbook.
Always discover the current device ID and build-products path; do not reuse
recorded snapshot identifiers.

Signing safety rules:

- Use `~/Library/Keychains/codexbar-dev.keychain-db`, never the crowded login
  keychain, for device-build signing.
- Never ask for, print, or store the signing-keychain password in chat or
  repository files. Its owner-only local password file must stay outside the
  login keychain.
- Keep `codexbar-dev.keychain-db` out of the normal keychain search list and
  keep `login.keychain-db` as the default keychain.
- Run signing commands through `./scripts/with-codexbar-keychain.sh`; first try
  `./scripts/unlock-codexbar-keychain.sh` after a reboot.
- Verify the live identity with `security find-identity` before acting. Do not
  treat a recorded certificate fingerprint as current, delete identities
  repeatedly, or reset the keychain unless the dedicated keychain is unusable.
- Use `./scripts/reset-codexbar-keychain.sh` only for the recovery case described
  in the runbook. It backs up the old keychain before recreating it.

## Browser Auth Takeaways

- For browser-based provider auth (e.g. Claude), search that provider's current
  public docs/issues before changing the flow. Claude Code currently expects a
  localhost callback style such as `http://localhost:<port>/callback`.
- Start the local callback listener before opening Safari/`ASWebAuthenticationSession`, and keep the exact redirect URI consistent between authorize and token exchange.
- Browser-session providers should only become configured after their secret/token is saved. A suggested account label is not proof of auth.
- If auth appears to succeed but the provider is missing from settings/dashboard, check `ProviderConfigurationStore.isConfigurationReady`, `hasSecret`, account-specific keychain IDs, and status text first.
- After auth or signing changes, run simulator tests, then build/install/launch on the connected iPhone with `devicectl`.
