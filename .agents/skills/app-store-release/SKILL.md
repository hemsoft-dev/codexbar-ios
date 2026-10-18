---
name: app-store-release
description: "V1.1 - Commands: Prepare, Upload, Submit, Resume. Prepare, validate, upload, and submit CodexBar production releases through App Store review."
disable-model-invocation: true
compatibility: Requires macOS, Xcode, PowerShell 7, git, GitHub and App Store Connect access, CodexBar signing authority for upload stages, plus the perfection, issue-to-pr, process-pr, playwright-cli, and unslop skills.
hooks:
  PostToolUse:
    - matcher: "Read|Write|Edit"
      hooks:
        - type: prompt
          prompt: |
            If a file was read, written, or edited in the app-store-release directory (path contains 'app-store-release'), verify that history logging occurred.

            Check if History/{YYYY-MM-DD}.md exists and contains an entry for this interaction with:
            - Format: "## HH:MM - {Action Taken}"
            - One-line summary
            - Accurate timestamp (obtained via `pwsh -NoLogo -NoProfile -Command 'Get-Date -Format "HH:mm"'`, never guessed)

            If history entry is missing or incomplete, provide specific feedback on what needs to be added.
            If history entry exists and is properly formatted, acknowledge completion.
  Stop:
    - matcher: "*"
      hooks:
        - type: prompt
          prompt: |
            Before stopping, if app-store-release was used (check if any files in app-store-release directory were modified), verify that the interaction was logged:

            1. Check if History/{YYYY-MM-DD}.md exists in app-store-release directory
            2. Verify it contains an entry with format "## HH:MM - {Action Taken}" where HH:MM was obtained via `pwsh -NoLogo -NoProfile -Command 'Get-Date -Format "HH:mm"'` (never guessed)
            3. Ensure the entry includes a one-line summary of what was done
            4. If retrospectives are enabled, verify retrospective check was performed

            If history entry is missing:
            - Return {"decision": "block", "reason": "History entry missing. Please log this interaction to History/{YYYY-MM-DD}.md with format: ## HH:MM - {Action Taken}\n{One-line summary}"}

            If history entry exists:
            - Return {"decision": "approve"}

            Include a systemMessage with details about the history entry status.
---

# App Store release

Take a merged CodexBar product state through one production App Store release.
Compose the repository's existing release documentation and skills; do not
replace their instructions here.

## Commands and authority

- **Prepare** (default): resolve the release boundary, audit changes, prepare
  copy, and validate. Stop before archive upload and every App Store Connect
  write.
- **Upload**: run Prepare, archive, export, upload exactly once, and wait for
  processing. Stop before selecting a build or changing submission metadata.
- **Submit**: resume a processed upload, verify the storefront, and submit for
  App Review only with exact final-submission authority in the current task.
- **Resume**: inspect GitHub, local artifacts, and App Store Connect first, then
  continue at the first incomplete checkpoint allowed by the ledger's recorded
  mode. A bare Resume never expands Prepare, Upload, or Submit authority.

An instruction to prepare, validate, archive, export, upload, or use TestFlight
is not authority to click **Submit for Review**. Ask immediately before that
action unless the current task explicitly authorizes submission of the exact
version and build. Never automate agreements, tax, banking, certificate
revocation, account roles, or a material release-policy choice.

## Compose these sources

- Follow `AGENTS.md` for issue-first repository changes, changelog policy,
  signing safety, and the reviewed PR path.
- Treat `CHANGELOG.md` as release history and `APP-STORE.md` as the release
  tracker. Check `PRIVACY.md`, `SUPPORT.md`, `DEVICE-DEPLOYMENT.md`, Fastlane
  metadata, Xcode settings, and the signing/export scripts as applicable.
- Invoke the repository `perfection` skill for its seven local lint,
  strict-concurrency, build, and test gates. Verify separate readiness checks
  documented by the skill and the live repository requirements.
- Invoke `issue-to-pr` for release-tracker changes and
  `process-pr` when resuming their review gate. Do not bypass checks,
  reviews, or merge protections.
- Prefer direct read-only App Store Connect APIs when they provide the needed
  evidence. Invoke `playwright-cli` when the rendered authenticated page is
  required. Follow its attached-browser identity and tab-ownership checks,
  inspect the exact origin before each write, and leave the task tab on the
  final result. Use Pi computer controls only when browser automation cannot
  reach the required window.
- Invoke `unslop` for customer copy. Product and privacy claims still require
  evidence from the shipping build and repository.

Stop before the affected stage if a required companion skill is unavailable.
Install or enable that skill instead of improvising its GitHub, browser, or
writing workflow.

## Release ledger

Use one release issue as the live ledger until reviewed tracker changes merge.
At the start, record the authorized mode and its source task. At every
checkpoint record the version/build, source commit SHA, timestamp, actor,
completed command, evidence or artifact path, identifiers returned by Apple,
skipped checks, and next safe resume action. Resume inherits that mode. Only a
new current-task instruction that explicitly grants Upload or exact Submit
authority may expand it, and the ledger must record that grant before the first
newly authorized write. Do not record credentials, cookies, signing passwords,
private keys, or other secrets.

Before any repository edit, create or identify the release issue. Make changes
only from synchronized `main` after intended product PRs have merged, using an
issue branch and reviewed PR. Before every App Store Connect write, re-read the
version/build state and ledger to prevent duplicate uploads, build selection,
metadata edits, or submissions.

## Workflow

### 1. Resolve the release boundary

1. Inspect the public/App Store Connect version and build, the last version
   that reached distribution, any version already uploaded or submitted, and
   the intended new version. App Store Connect state wins over assumptions in
   repository headings.
2. Resolve the last-live commit or tag and candidate SHA. Confirm synchronized
   `main` contains every intended merged PR and no later unintended work.
3. Enumerate every submitted executable bundle from the archive/export plan.
   Verify `MARKETING_VERSION` and build number in every relevant app,
   extension, widget, Watch product, and configuration.
4. Record boundary evidence and checkpoint `boundary-resolved`.

Resume by recomputing the boundary. Stop if the live version, candidate SHA, or
intended version differs from the ledger.

### 2. Audit changes since the last live release

1. Diff the last-live commit/tag to the candidate. Reconcile commits, merged
   PRs, linked issues, App Store Connect state, and the candidate changelog.
2. Classify each shipped change as customer-visible or Developer Experience.
   Flag omissions, duplicates, planned-but-unshipped claims, internal wording,
   and edits to published history other than factual corrections.
3. Do not use the latest changelog heading as the release boundary. In
   particular, exclude changes already distributed even if they share the
   candidate's unreleased section or were skipped by an earlier submission.
4. Record the evidence range and checkpoint `changes-audited`.

### 3. Prepare release copy

1. Date the candidate changelog section only when the candidate is final.
   Preserve customer sections separately from `Developer Experience`.
2. Derive **What's New** only from verified customer-visible changes after the
   last live release. Map each sentence or bullet to changelog entries and show
   the exact final copy before any App Store Connect write.
3. Do not produce cumulative multi-version copy unless the current task
   explicitly requests a broader announcement. Keep App Store copy within its
   current limit, lead with user benefit, use product terms, omit internal
   implementation detail, and reconcile privacy/data-flow claims with the
   shipping build and `PRIVACY.md`.
4. Prepare a longer GitHub release or announcement only when requested. Record
   the copy-to-changelog map and checkpoint `copy-approved`.
5. Deliver the changelog, release notes, version settings, and other
   release-preparation edits through the release issue's PR. Pass its reviews,
   required checks, and merge gate, then merge it before building the release.
6. Synchronize `main`, confirm the intended preparation PRs are present, and
   resolve a new immutable candidate SHA. Record checkpoint
   `release-preparation-merged`. Do not validate or archive the review branch.

### 4. Run release validation

Dispatch `ci.yml` against the frozen candidate ref and verify its resolved
`headSha`. Before archive/upload, require SwiftLint, Strict concurrency, iOS tests,
watchOS tests, SwiftPM smoke tests and Full iOS UI validation to succeed for that
exact merged SHA. Require Xcode 26.6 / 17F113 with the recorded compatible
26.5 runtimes. Each UI family must pass the manifest's original 29,
supplemental 6, synthetic commerce 14 and native commerce 2 journeys, plus
three separate preparation/reset calls. The marketing capture is excluded.
Require exact discovered/executed identities and zero skips or expected failures.
The iOS risk job must merge the full ordinary unit result with native
preparation 1, commerce 25, Germany preparation 1 and Germany storefront 1.
Require the real disjoint-line xccov proof, per-input provenance and nonempty
counters. A setup, product, transaction-finish or reset failure fails the gate;
local 27.1 evidence and historical passes cannot waive it.
Any source change invalidates the run. Routine PR automation requires only
SwiftLint; do not recreate retired automatic native gates or main-push reruns.
Also run the existing manual `security-analysis.yml` and
`usage-history-performance.yml` requirements for the exact candidate. Retain
their tool pins, source-bound reviews, exclusions and budgets.

1. Confirm `release-preparation-merged`, synchronized `main`, and the recorded
   candidate SHA. Require
   `git status --porcelain -- . ':(exclude).agents/skills/app-store-release/History/**'`
   to be empty. The full status may contain only the inspected History entry
   required by this skill's hooks; record that diff in the ledger. Stop if any
   other tracked or untracked repository content could alter the build. Run
   `perfection` for its seven local gates: pinned repository-wide SwiftLint,
   complete strict concurrency, iOS build and tests, SwiftPM smoke, and watchOS
   build and tests. The score excludes separate UI, function-risk, security,
   and performance checks; verify applicable results before archive creation.
2. Record exact commands, start/end timestamps, candidate SHA, results, and
   artifact locations. Retry an infrastructure or simulator flake only after
   preserving its evidence and explaining why it is non-product; never use a
   retry to hide a reproducible failure.
3. Verify metadata limits, support/privacy URLs, App Store icon, package graph,
   screenshot inputs, release-copy diff, and repository-required checks that
   apply before archive creation.
4. Record skipped TestFlight or physical-device checks as **skipped**, with
   scope and reason. Never convert them to passed. Checkpoint
   `candidate-validated` only when blocking failures are fixed and rerun.

### 5. Archive and upload

Skip this entire stage when the recorded mode is Prepare. Resume does not
change the recorded mode.

1. Recheck `candidate-validated`, current SHA, App Store Connect version/build,
   and signing authority. Immediately before the archive command, require the
   current SHA to equal the validated SHA and rerun the history-excluding status
   command from stage 4. Inspect the full status and allow only the skill's
   recorded History diff. Stop instead of archiving any other unreviewed
   worktree content. Follow the repository signing runbook without changing
   keychain policy or exposing secrets.
2. Create the signed Release archive and local App Store export. Inspect every
   submitted bundle for consistent version/build, distribution signature,
   provisioning, required privacy manifests, and export-compliance
   declarations. Run the repository export-compliance verifier against source
   and archive/exported product.
3. Record archive/export paths and checkpoint `archive-verified` before upload.
4. Re-read App Store Connect. If this build or a valid upload already exists,
   record its identifier and resume processing instead of uploading again.
   Otherwise upload once and record the returned upload/build ID immediately.
5. Wait for processing and validation. Record Apple's final binary state and
   checkpoint `upload-processed`; do not select or submit the build yet.

### 6. Verify App Store Connect

Skip this stage when the recorded mode is Prepare. Upload mode may inspect but
must not write. Resume does not change the recorded mode.

Using the claimed browser tab, verify and record:

- selected version and build, processed state, and export compliance;
- localized release notes and other metadata;
- screenshots for every maintained iPhone, iPad, and Apple Watch family;
- privacy answers, review notes, contact details, age rating, app icon,
  support URL, and privacy URL;
- price, regions, availability, automatic/manual release, phased/immediate
  rollout, and whether the existing star rating is kept;
- TestFlight verification and every explicitly accepted omission.

In Submit mode, re-read App Store Connect and select the exact processed build.
Apply only the exact approved version-localized metadata, one idempotent write
at a time, and re-read each saved value. This authority does not cover a new
global-metadata or release-policy choice. Upload mode must not perform these
writes.

Re-verify the selected build and saved metadata, preview the storefront, show
the exact final **What's New** copy again, and record checkpoint
`submission-ready`. Pause for authentication, legal or account changes,
missing signing authority, missing metadata, or a release policy that differs
materially from the ledger.

### 7. Submit and record the outcome

For these first CodexBar Pro products, submit the app, subscriptions and lifetime
purchase through the App Store Connect website. Apple's
[first in-app purchase submission rule](https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases)
and [first subscription submission rule](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review)
require the website with an app version; review-submission API operations do not
apply. API checks and eligible build selection may prepare the version, but do
not add or submit these first product items through the API. Re-read the website
submission result and record all app/product relationships in the ledger.

1. Confirm `submission-ready`, exact version/build, unchanged candidate SHA,
   and exact current-task authority for **Submit for Review**. Otherwise stop
   and ask for confirmation.
2. Submit once. Confirm the resulting App Store Connect state and record the
   submission ID, version, build, submitter, timestamp, release policy,
   rollout, rating choice, and Apple's displayed review estimate.
3. Leave App Store Connect on the submission result. Record checkpoint
   `submitted` and report all skipped TestFlight or physical-device work.
4. Update `APP-STORE.md` with the final identifiers and state. Add the next
   `Unreleased` section and any remaining release metadata through the release
   issue, branch, PR, automated review, required checks, and merge gate. Do not
   edit or merge directly on `main`.

### 8. Continue the approved 2.0 rollout

Submission is a checkpoint, not completion of issue #470. Keep its ledger and
issue #469 open until their actual acceptance criteria are met. Follow the
[approved launch sequence](../../../APP-STORE.md#approved-launch-sequence) and
record requested/actual times and storefront observations separately.

For the selected 2.0.0 build 5, the planned October 18, 2026 UTC submission
corresponds to cutoff `2026-11-01T00:00:00Z`, October 31 at 8:00 PM EDT.
Recheck the actual plan before final qualification and submission. A changed
cutoff, build, source or release copy requires a newly qualified candidate.
Submit all first-time Pro products with the app, manual release, phased release
off and the existing US$3.99 app price. Do not infer release or price-change
authority from Submit mode alone; use the already recorded launch authority.

After approval, release only with at least six full days before the cutoff.
Otherwise replace the unreleased 2.0 build with a later cutoff and requalify.
Wait a full 48 hours after release and verify several storefronts serve 2.0
before scheduling worldwide Free about 72 hours before the cutoff. Verify
every storefront is Free before the cutoff; never raise the price afterward.
If paid distribution cannot end safely, apply the approved remove-from-sale
rollback at least 48 hours before the cutoff and verify several storefronts.
Keep production original-purchase/Family Sharing checks pending for Franz;
they are not an agent delivery prerequisite or an invented pass. Paid Apps
Agreement and Small Business Program status remain unverified until checked.

## Recovery

- **Interrupted upload:** inspect organizer/transporter logs and App Store
  Connect by exact version/build and upload ID. Resume processing if Apple
  received it; upload again only when evidence proves it did not.
- **Processing delay:** keep `upload-processed` incomplete, record Apple's
  current state and next check, and make no duplicate upload or submission.
- **CI or simulator flake:** preserve the failed run, distinguish hosted-runner
  or simulator evidence from product failure, retry once when justified, and
  fix/revalidate any reproducible failure.
- **Browser-session loss:** release or record the lost tab claim, reauthenticate
  without exposing session data, reclaim one tab, then re-read App Store
  Connect and compare it with the ledger before any write.
- **Repository interruption:** inspect the release issue, PR, checks, current
  branch/SHA, artifacts, and App Store state. Continue from the first
  unverified checkpoint; never infer completion from a local file alone.

## Completion report

Report the release boundary, candidate SHA, version/build matrix, changelog
range, exact copy, validation evidence, archive/export paths, upload and
submission IDs/states, metadata and release-policy decisions, PR/check state,
skipped verification, and the next resume action. A processed upload is not a
submission, and a submitted release is not a distributed release.
