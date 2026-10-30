# CI gate and manual analysis policy

Ordinary pull requests run pinned SwiftLint and the existing four lightweight
CI-policy assertions in one macOS job. These catch style violations and accidental
changes to automatic/manual triggers. Native strict-concurrency builds, iOS and
watchOS unit suites with function risk, and the SwiftPM smoke harness run only
through explicit `workflow_dispatch`, before a release or on demand.

CI has no `main` push trigger: it performs no deployment or productive post-merge
task, so duplicate post-merge validation and its notification obligation are
removed. Historical failures and cancellations remain visible. Separate security
and usage-history performance workflows remain manual and unchanged.

This policy implements [issue #419](https://github.com/HemSoft/codexbar-ios/issues/419),
following #325 and #337's earlier UI-only split. Full validation retains every
existing native workload, both UI families, thresholds and artifacts.

## Rollout status

The intended live `main required quality checks` ruleset requires only SwiftLint,
with strict branch freshness and no bypass actors. Codex current-head review and
thread resolution remain mandatory. The four manual-only native statuses must
not strand ordinary PRs; their skipped PR results are not validation evidence.
The implementation PR records completed full-dispatch proof and the exact live
ruleset reconciliation before merge. Classic branch protection is absent; the
repository ruleset supplies required statuses.

## October 8 automatic-work comparison

The completed baseline is [run 37690509455](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37690509455)
at `622f2e3a2ab5e35f4b1a21c23d34e9016edd6efb`: 21m 09s workflow elapsed,
21m 01s completed job span, and 32m 29s summed completed job runtime.
GitHub's timing API reports zero billable milliseconds for MACOS and UBUNTU;
that API value does not turn elapsed runner time into a dollar estimate.
The completed candidate [run 37753142813](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37753142813)
at `8092f2a0dec5755530a54fdc942583de2daa97fc` used 51 seconds workflow
elapsed, 42 seconds completed job span, and 42 summed completed job-seconds.
The timing API again reports zero billable milliseconds for MACOS and UBUNTU.
Workflow elapsed and summed runner time both decreased. Skipped jobs contribute
no runtime and supply no validation evidence. Manual dispatch cost is recorded
separately in the implementation PR.

| Completed automatic run | Workflow elapsed | Completed job span | Summed job runtime | API billable MACOS / UBUNTU |
| --- | ---: | ---: | ---: | ---: |
| Baseline 37690509455 | 1,269s | 1,261s | 1,949s | 0ms / 0ms |
| Candidate 37753142813 | 51s | 42s | 42s | 0ms / 0ms |


An earlier candidate, including the stronger trigger assertions, also passed in
[run 37754838237](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37754838237)
at `3ec659df3a472113cf9b066d9eefffe906c9d748`: 70 seconds workflow elapsed,
58 seconds completed job span and summed job runtime, with zero API-reported
billable milliseconds on MACOS and UBUNTU. This measurement predates the manual
UI-helper repairs, whose Swift files are scanned by automatic SwiftLint. The
implementation PR must record completed workflow elapsed and summed runner time
for its latest head after any further source or documentation change. Historical
candidate measurements do not satisfy that final cost-ceiling proof.

Trigger/job changes: remove `push: branches: [main]`; retain `pull_request` and
`workflow_dispatch`; make four native quality jobs dispatch-only. Move the
existing four CI-policy assertions from the smoke job to SwiftLint without
adding another invocation. No new job, matrix entry, destination, retry, longer
timeout, native test workload or analysis pass is introduced. Manual jobs retain
their existing runners, timeouts and failure rules.

## Measured inventory

The snapshot covers the latest 100 workflow runs, September 1, 2026 at
4:47 a.m. through September 6 at 5:13 p.m. EDT. The
[workflow records](docs/ci/2026-09-06-runs.csv) retain all 100 runs, including
four cancelled runs that created no jobs. The snapshot contains 348 jobs from
the latest attempt of each remaining run. The
[job records](docs/ci/2026-09-06-jobs.csv) retain every outcome, source commit,
event, timestamp and job URL. The
[computed summary](docs/ci/2026-09-06-summary.json) records selection and
aggregation rules. This is a development-period sample, not an estimate of
the failure probability of unchanged code.

Durations below use successful completed jobs only and exclude queue time.
P90 is the nearest-rank percentile. Failures, cancellations and the one
unfinished iOS job are retained in the outcome counts, not treated as passes
or silently excluded from the inventory.

| Job | Successes / total | Median | P90 | Longest success | Timeout at inventory |
| --- | ---: | ---: | ---: | ---: | ---: |
| SwiftLint | 62 / 63 | 40s | 49s | 54s | 10m |
| Strict concurrency | 56 / 63 | 4m 03s | 5m 13s | 6m 16s | 30m |
| iOS tests | 28 / 63 | 18m 42s | 40m 08s | 49m 34s | 50m |
| watchOS tests | 55 / 63 | 4m 45s | 6m 32s | 7m 04s | 30m |
| SwiftPM smoke tests | 60 / 63 | 1m 08s | 1m 22s | 1m 29s | 15m |
| Swift security analysis | 9 / 25 | 31m 09s | 39m 52s | 39m 52s | 60m |
| Usage history Release budget | 5 / 8 | 5m 01s | 5m 25s | 5m 25s | 20m |

A later successful [CI run on September 10,
2026](https://github.com/HemSoft/codexbar-ios/actions/runs/34459470256)
took 52m 10s and consumed 61.9 summed macOS job-minutes. Its iOS job used
51m 07s, including 12m 24s for unit tests, 19m 32s for iPhone UI journeys, and
17m 21s for iPad UI journeys. This completed-run sample supplied the cost basis
for issue #337.

All 54 cancelled jobs have an explanatory GitHub annotation. Fifty-three
were superseded by a newer request, and one was the
[security extraction timeout](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447013/job/101543699257).
The timeout reached the 60-minute execution limit before analysis and the
findings gate ran. It supplies no security result. Superseded jobs are not
evidence of flaky tests.

The eight iOS failures occurred in two unit-test steps, one iPhone UI step
and five iPad UI steps. The required destination aggregator correctly failed
the six UI cases. There were no annotated iOS timeouts in this snapshot.
Raw logs include simulator launch/background-assertion failures, such as
[this unit-test run](https://github.com/HemSoft/codexbar-ios/actions/runs/33957762004)
and [this UI run](https://github.com/HemSoft/codexbar-ios/actions/runs/34010249721),
as well as actual UI assertions, including
[an unreachable accessibility-size control](https://github.com/HemSoft/codexbar-ios/actions/runs/33989302706).
Job-level outcomes alone therefore cannot separate simulator reliability from
application or test defects. These failures warrant diagnosis, not an automatic
rerun policy or removal of the checks.
The six security failures include extraction/setup and findings-gate failures
during development; they must not all be classified as infrastructure noise.
The single strict-concurrency failure occurred in its compiler-check step.

The Release budget's three failed workflow runs produced four retained failed
attempts, including a rerun. All four artifacts report only inconclusive noise
findings, with no latency or retained-data regression. Their failed step was
the paired comparison. The
[latest noisy result](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447047/job/101543620434)
had a 20.06% run CV for one-account recording and 16.90% for 25-account series
generation, exceeding the unchanged 15% limit. Its six median latency ratios
were between 0.831 and 1.091, with no latency or retained-data regression.
The artifact establishes an inconclusive measurement, not a regression or a
specific cause. Its machine metadata does not contain process-by-process load
or thermal observations.

## Automatic gate budget

SwiftLint is the sole automatic required status. Its existing ten-minute timeout
and pinned lint command are unchanged; it also executes the four existing
configuration assertions. The four native quality jobs are dispatch-only, with
their original 30/30/30/15-minute limits. Do not recreate their automatic triggers,
require their skipped PR statuses, or dispatch the full gate for routine PRs.

The historical inventory below predates this policy. Completed candidate
measurements above, rather than estimates, establish the automatic cost change.
Concurrency cancellation cannot recover runner time already spent.

The manual full gate gives each iPhone and iPad worker its own 90-minute limit.
They run independently with fail-fast disabled and publish separate artifacts.
`Full iOS UI validation` is a fail-closed aggregate of both workers; a failed,
cancelled, or skipped family cannot pass the release gate.
Keeping the UI suites intact preserves their correctness decisions without
charging every review-fix commit for both simulator families. Inspect unit
tests, simulator startup, each UI family, and artifact steps separately when a
manual run is slow.

Security's 31-minute median and incomplete 60-minute attempt justify a
separate manual job. Retain its 60-minute cap. Performance remains manual
because measurement noise can prevent a usable decision, even though its
successful runs took about five minutes. Retain its 20-minute cap and all
current thresholds.

## Release gate and manual analysis ownership

Do not run the full CI gate for routine pull requests, including UI changes.
After the intended release changes have merged, select a release-candidate
branch or tag, record its resolved SHA, and dispatch the gate once. The dispatch
first runs all five quality jobs. If they pass, independent manual workers
run all twenty-nine journeys on iPhone and iPad. `Full iOS UI validation` passes only after both workers pass.
A failed iPhone family does not suppress the iPad family or its retained failure
artifacts. The account-menu comparison remains a separate manual-only mode.

The release cannot proceed unless every job in that manual run passes for the
exact candidate SHA. Any candidate change invalidates the result and requires a
new manual run. Do not reuse a run from an individual pull request as release
evidence.

Run security analysis for authentication, networking, credential storage,
analyzer or toolchain changes, and release preparation. Run the Release budget
for history persistence, chart generation, benchmark or toolchain changes, and
release preparation. The maintainer requesting any manual run owns inspecting
its result and recording its disposition in the related issue, pull request, or
release record. A green automatic gate does not imply a manual gate ran.

Record the release candidate's resolved SHA immediately before dispatch and
confirm the run's `headSha` afterward. A branch can move between those
operations.

```bash
set -euo pipefail
release_candidate_ref=<release-candidate-branch-or-tag>
encoded_ref="$(jq -rn --arg ref "$release_candidate_ref" '$ref|@uri')"
release_candidate_sha="$(gh api \
  "repos/HemSoft/codexbar-ios/commits/$encoded_ref" --jq '.sha')"

gh workflow run ci.yml --repo HemSoft/codexbar-ios \
  --ref "$release_candidate_ref"
gh workflow run security-analysis.yml --repo HemSoft/codexbar-ios \
  --ref "$release_candidate_ref"
gh workflow run usage-history-performance.yml --repo HemSoft/codexbar-ios \
  --ref "$release_candidate_ref"

gh run view <run-id> --repo HemSoft/codexbar-ios \
  --json headSha,event,status,conclusion,url,jobs
gh run download <run-id> --repo HemSoft/codexbar-ios \
  --dir <new-evidence-directory>
```

Compare the reported `headSha` with `$release_candidate_sha`. Record the manual
full gate as passed, failed, or not run. Never present an unrun or stale gate as
passing. UI result bundles, logs, summaries, and failure screenshots expire
after 14 days.

For security, inspect complete production source reach, compiler/extraction
diagnostics, raw SARIF, reviewed findings and blockers in `gate.json`. Preserve
the distinction between three reviewed findings and zero findings. Artifacts
expire after 14 days. Copy needed release evidence before expiry. A missing
report, timeout, stale baseline or unreviewed high-severity finding requires a
recorded investigation. Refresh a reviewed baseline only through the source
and finding review defined in [SECURITY-ANALYSIS.md](SECURITY-ANALYSIS.md).

For performance, inspect raw reference/candidate samples, machine and toolchain
metadata, fixture identity, run order and every finding in `result.json`.
Artifacts expire after 30 days. Report regression, inconclusive measurement and
execution failure separately. Preserve slow samples. Do not relax the 1.25
latency ratio, 15% CV or retained-data limits to obtain a pass. Follow
[USAGE-HISTORY-PERFORMANCE.md](USAGE-HISTORY-PERFORMANCE.md) for independent
paired experiments and the intentional-slowdown proof.

A confirmed security or performance regression remains actionable after moving
analysis outside branch protection. The requesting maintainer owns the fix or
an explicit documented disposition before the affected release. If discovered
after merge, record the affected commit and choose a corrective PR or revert;
do not turn an incomplete run into release evidence. Manual runs are not a
substitute for the required correctness checks, and pending manual evidence
must remain visible in issue #325 until its criteria are met.

## Focused account-menu comparison

The existing manual `CI` dispatch also accepts `ui_validation_mode=account-menu-comparison`.
This names the manual job `Account menu comparison`, never `Full iOS UI validation`.
It runs only the complete original Google customization/relaunch journey on each
family for an exact ancestor baseline and the dispatched candidate. The comparison remains dispatch-only; it creates no automatic PR or main-push
work. The four
existing CI policy tests retain their count and full-UI assertions, and also
check PR-only lint, dispatch-only native work and the comparison selector.

```sh
gh workflow run ci.yml --repo HemSoft/codexbar-ios \
  --ref <candidate-branch-or-tag> \
  -f ui_validation_mode=account-menu-comparison \
  -f comparison_base_sha=<exact-40-character-ancestor-sha>
```

The runner requires the Xcode pin from `scripts/function-risk/policy.json`, checks
the dispatched candidate SHA and baseline ancestry, and archives both exact source
revisions. Each source/family uses a fresh owned simulator, without retries. The
candidate must pass exactly one journey with no skips or expected failures on
both families. A baseline pass is retained as a non-reproduction; only the exact
known Configure Account menu assertion may be classified as a reproduced baseline
failure. Other assertions, simulator failures and missing summaries fail the
comparison. Inspect `comparison.json`, all four summaries/logs/result bundles,
screenshots and the candidate iPad recording in the existing UI artifact.

A focused comparison is not release evidence. Default `full` dispatch still runs
the billing fixtures and all twenty-nine journeys per family, including the existing
both-destinations and exact-count guards.

Run the new lightweight classifier/device-selection regressions explicitly locally:

```sh
python3 -m unittest discover -s scripts/tests/manual -p 'test_account_menu_comparison.py' -v
```

## Recheck the policy

```sh
python3 -m unittest discover -s scripts/tests -p 'test_ci_policy.py' -v
gh api repos/HemSoft/codexbar-ios/rules/branches/main
gh api repos/HemSoft/codexbar-ios/branches/main/protection
gh run list --repo HemSoft/codexbar-ios --limit 100 \
  --json databaseId,workflowName,event,conclusion,createdAt,startedAt,updatedAt,url
gh api 'repos/HemSoft/codexbar-ios/actions/runs/<run-id>/jobs?per_page=100&filter=latest'
```

Inspect all pages when more than 100 jobs or annotations exist. Compute job
duration from each job's own start and completion timestamps, not the
workflow's last update time. Confirm an ordinary PR run marks `Full iOS UI
validation` skipped and spends no time in either UI destination. Confirm a
manual `CI` run records `workflow_dispatch`, matches the reviewed SHA, and runs
both destinations after all five quality jobs pass. The security-analysis and
usage-history performance workflows must contain only `workflow_dispatch`.
Keep failures and cancellations in the inventory when refreshing measurements.

## Manual iOS release job timeout, October 18

Issue [#490](https://github.com/hemsoft-dev/codexbar-ios/issues/490) raises the
manual-only `iOS tests` job timeout from 30 to 45 minutes. The job runs only on
`workflow_dispatch`, so automatic pull-request work, triggers, jobs, matrices,
retries and SwiftLint's ten-minute timeout are unchanged. The CI-policy assertion
for the new value runs inside the existing SwiftLint job and adds no work there.

Measured need: the job had never completed its full native workload within 30
minutes. [Run 39159924940](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39159924940)
used 27 minutes 45 seconds of the budget by the end of native commerce, before
the Germany preparation and storefront phases or function-risk scoring had run.
Its 25-minute test step covered the native build, 1,106 ordinary tests, native
preparation and 25 native commerce tests. The new budget leaves room for the
remaining phases and scoring without retries.

## Manual UI sharding

[Issue #517](https://github.com/hemsoft-dev/codexbar-ios/issues/517) partitions only
`workflow_dispatch` UI work. Each iPhone/iPad family has three original shards,
one supplemental shard, one synthetic-commerce shard and one native-commerce
shard. Each worker retains its 90-minute timeout; no timeout increase is used.
The existing Xcode 26.6 / 17F113 and iOS 26.2 / 23C54 verification remains mandatory.

The retained [hosted run](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39810829566)
took 7,214 seconds for the iPad original phase, including build and process
overhead. Its 29 test durations sum to 6,624.54 seconds; the two longest tests
were 1,620.38 and 1,603.84 seconds. Measured greedy partitioning assigns 2,212.66,
2,205.04 and 2,206.84 test-seconds to the original shards. These are historical
allocation inputs, not claimed candidate run times. The implementation PR records
completed candidate measurements and the final exact-head hosted gate result.
The [baseline data](docs/ci/issue-517-baseline.json) retains the source run and
per-test values without downloading the multi-gigabyte result bundles.

The automatic SwiftLint job, its steps, the four lightweight policy test methods,
triggers, native-job dispatch conditions and automatic timeouts are retained.
The new shard fixture suite runs only manually. Before/after automatic workflow
elapsed time, summed job runtime and API billing values are recorded in the PR;
manual shard durations are reported separately. Neither a queue delay nor an
estimated shard budget is proof that automatic work stayed within the ceiling.

`Full iOS UI validation` now requires all twelve successful workers and their
current-source proofs. The compact artifacts identify every executed method,
qualified toolchain/runtime, source SHA/fingerprint and owned simulator. The
aggregate rejects missing, duplicate or substituted shards. The 53 journeys per
family include usage-detail and missing-quota regression coverage; the original local 29-test command
is unchanged. StoreKit preparation and final reset cannot be split across workers.

## Manual aggregate event hints

The existing manual aggregate can post a source-linked hint to the run's exact
current open same-repository PR targeting the default branch. The
[approved v2 proposal](https://github.com/hemsoft-dev/chief/blob/8d9fb8d323d100333853a56174318f006d86e093/proposals/chief-40/manual-comment/README.md)
supplies the inline script. It authenticates run, attempt, repository, branch,
head, jobs and current PR through GitHub before posting. PR/comment text and
payload URLs supply no instructions or authority. Only the verified Actions
bot's exact event marker suppresses a serial duplicate; POST has no automatic
retry or fallback.

Only `ios-ui-tests` gains job-level `pull-requests: write`, alongside its existing
Actions/Contents read permissions. This grant applies to every manual execution
of that job, including main and no-PR runs. The notifier's guards do not remove
the token's rights. Main, the current default branch, tags and runs without one
matching open current-head PR produce no comment. Matrix workers and automatic
jobs receive no new permission. Triggers, jobs, native steps, needs, matrices,
timeouts and concurrency are unchanged.

Hints run after the matrix reaches the aggregate. They provide no early-failure
notification or completion guarantee. A success hint means passed-so-far;
post-steps and the workflow may still fail. Hard timeout, cancellation or runner
death can prevent delivery. Unknown/authentication/transport failures stay
visible and may fail an otherwise successful aggregate. Concurrent writers,
head moves and eventual consistency prevent an exactly-once guarantee. The
existing PR watch must already belong to the intended owner, who independently
verifies actual Actions state after waking.

Run `node --test scripts/tests/manual/test_manual_ci_comment.mjs` with Node 24
to exercise the actual inline script against mocked GitHub metadata, target
selection, failures and deduplication. The manual shard fixture suite also
verifies the exact approved script and proves that removing its single step
and permission grant restores the prior workflow bytes. These tests add no
automatic PR workload. The proposal's 39 offline checks and the local adaptation
checks do not prove live delivery. [Chief issue #40](https://github.com/hemsoft-dev/chief/issues/40)
stays open until a real bot comment and the exact owner-thread wake are verified
on a normal required qualification run. Existing dispatches cannot acquire the
new step, and no dispatch is added solely to test notification.

Rollback removes the final notifier step and its aggregate write grant, keeping
all quality gates, prior evidence and existing watches intact.
