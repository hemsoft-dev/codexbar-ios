# Usage-history performance budget

Issue [#310](https://github.com/HemSoft/codexbar-ios/issues/310) adds a regression
budget for the existing main-actor history implementation. Production behavior
is unchanged. The budget compares Release binaries built on the same machine
against frozen source revision `3395ee6094ce8e4199577f7ede493e3a50ee1269`.
It does not turn a Mac measurement into an iPhone responsiveness target.

## Run the benchmark

From the repository root on a Mac with Xcode installed:

```sh
python3 scripts/usage-history-performance/run.py --output /tmp/history-performance
```

The runner selects `/Applications/Xcode.app/Contents/Developer`, builds with
`swift build -c release`, and sets `TZ=UTC`. It archives the baseline commit in a
unique temporary directory, copies the current benchmark source into that
archive, and adds only its executable target to the baseline package manifest.
Both binaries explicitly request Darwin user-initiated QoS on the main thread
before fixture creation and verify it around each timed operation. Reports record
the observed kernel class (25); live measurement rejects missing or different
scheduling evidence. The `pthread_set_qos_class_self_np` call changes a running
thread; setting `Thread.qualityOfService` after startup does not. This follows
Apple's [task and thread QoS guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html).
QoS does not guarantee a particular physical core or waive the variance ceiling.
Each operation also records main-thread CPU milliseconds from the kernel thread CPU clock, alongside its original wall time. These observations diagnose scheduling loss versus variability in executed work. They never replace wall-clock latency or its variance gate. Live measurements require all seven finite positive CPU observations per operation; historical replay keeps its original contract.
Historical fixture replays remain historical and do not prove this live scheduling
contract.

The runner sets `SWIFT_DETERMINISTIC_HASHING=1` only when launching the two
benchmark binaries. Swift's [benchmark instructions](https://github.com/swiftlang/swift/blob/main/benchmark/README.md)
require this to prevent random hash-collision changes from affecting measurements.
Both sides report the setting and an actual standard-library hash probe. Live
comparison requires the probes to match across every process. The runner does not set this flag for app builds or tests. Historical randomized
reports cannot qualify this deterministic comparison, and hash behavior remains
compiler-specific. No samples or budgets are changed.

Both sides exercise the same fixture and public API. No production source,
branch, worktree, or baseline file is rewritten. The temporary archive is
removed on exit; each Swift process removes its unique `UserDefaults` suite.

The output includes build logs, raw JSON for every process, machine/toolchain
metadata, the fixture SHA-256, and `result.json`. An invalid fixture, failed
build, missing measurement, excessive noise, latency regression, or resource
regression exits nonzero. A failed build is not a detected slowdown.
Use a new or empty output directory for every run. The runner rejects old
artifacts so a failed attempt cannot reuse an earlier result as evidence.

Each process also retains its stderr and before/after machine snapshots with
load averages, the thermal observations reported by `pmset`, virtual-memory
counters, and the 20 busiest executable names. Command arguments are omitted.
Unavailable probes remain visible as diagnostic errors. These observations sit
outside the timed regions and never filter samples or alter the gate. Failed
processes and invalid JSON keep their raw output for investigation; neither can
produce a passing result.

For one diagnostic distribution without the comparison gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TZ=UTC \
  xcrun swift run -c release UsageHistoryBenchmark
```

The runner's `--pairs 5` option reproduces the calibration sample count. Ordinary
runs use three pairs. Compilation finishes before any timing begins.

## Workload and measurement

Each process runs 1, 10, and 25 accounts, with two stable Codex usage metrics per
account. Fixed values of 37% and 62%, fixed-width account IDs, and a fixed UTC
anchor make serialized-size comparisons deterministic. The fixtures contain:

- 240 frequent snapshots per account at two-hour intervals, spanning 20 days;
- 90 distinct UTC daily bins with one snapshot per metric, or 180 daily entries
  per account;
- fresh successful results for every account, with a new timestamp on each
  recording call.

The benchmark seeds `usageHistorySnapshots` and `usageHistoryDailySnapshots` in
a UUID-named `UserDefaults` suite. It validates loaded and persisted arrays for
unique IDs, every expected account, per-account counts, both metric identities,
and 90 daily bins. A fresh record replaces the oldest frequent sample and
today's two daily components. All-account chart generation must return one
aggregate usage series with 329 timestamps per account and a 62% value at each
point. This matches the current Codex chart's aggregation of the two metrics.

`ContinuousClock` measures seven batches per operation. The first two are
warmups. All seven values remain in each report; only the remaining five enter
the median. Recording measures one refresh of all accounts, including snapshot
rebuilding, sorting, daily aggregation, JSON encoding, and `UserDefaults.set`.
It does not measure eventual defaults-file durability. Series generation measures
five all-account chart passes per batch and reports milliseconds per pass.
Fixture creation, loading, correctness assertions, and resource inspection sit
outside both timed regions. The measured series results are consumed and checked.

After the timed batches, 32 additional fresh records exercise capped frequent
history, and seven daily rollovers exercise expiry of the oldest daily bin.
Every one of the 47 resource observations must retain 240 frequent and 180 daily
entries per account. The report records the combined encoded byte count from the
two stored defaults values at every observation.

These are retained model and serialized-data budgets. Allocation churn, process
RSS, and allocator caches are not leak evidence. This benchmark does not measure
retained heap objects or declare the app leak-free. Use Instruments with a
repeatable user journey for a separate memory investigation, following Apple's
[heap-memory guidance](https://developer.apple.com/videos/play/wwdc2024/10173/).

## Hardware matrix and failure policy

| Environment | Configuration | Role |
| --- | --- | --- |
| Mac17,4, Apple M5, 16 GiB, macOS 26.5.2 build 25F84, Xcode 26.6 build 17F113, Swift 6.3.3 | SwiftPM Release, arm64 | Committed calibration and disposable slowdown experiment |
| GitHub `macos-26` runner, actual model, architecture, OS, Xcode and Swift captured in each artifact | SwiftPM Release | Manual dispatch only |
| iPhone and iPad simulators in existing CI | Existing Xcode correctness/UI configurations | Correctness coverage, no latency budget |
| Physical iPhone/iPad and watchOS | Not benchmarked here | No inferred performance result or device latency claim |

The workflow `Usage history performance` runs only by manual dispatch. Its
`Usage history Release budget` job is not a required merge check. Automatic PR
and scheduled runs are disabled while
[issue #325](https://github.com/HemSoft/codexbar-ios/issues/325) investigates
measurement variability and evaluates CI policy. Existing correctness checks
remain required. See [CI-POLICY.md](CI-POLICY.md) for the measured time budget,
live required checks and manual failure ownership.

Select a reviewed branch in Actions > Usage history performance > Run workflow,
or run:

```sh
gh workflow run usage-history-performance.yml --repo HemSoft/codexbar-ios --ref <reviewed-branch>
```

Run it when reviewing history storage, chart generation or benchmark changes,
and during release preparation. The requesting maintainer owns reviewing
`result.json`, raw samples, machine metadata and logs in the
`usage-history-performance-<run-id>-<attempt>` artifact. Record the tested commit
and distinguish regression, inconclusive measurements and execution failure in
the related issue or PR. The job still fails on any budget or measurement-policy
failure; manual dispatch does not relax thresholds or turn noise into a pass.

Reference and candidate processes run sequentially in alternating order on the
same host. Arrange a measurement window without concurrent builds, simulator
startups or heavy foreground work.
Three paired runs give three ratios of candidate median to reference median;
the median ratio must meet the latency limit. The reference stays pinned across
pull requests, so repeated small changes cannot silently move the baseline.

The gate also checks the coefficient of variation across each side's run
medians. A noisy control or candidate is inconclusive and fails. Within-run CVs
are reported for diagnosis; medians reduce the influence of one or two isolated
outliers among the five retained timings. We do not delete slow samples or retry
until a green run appears. After an inconclusive run, inspect the artifact,
remove competing load, and rerun the whole paired experiment once. Persistent
noise needs investigation before changing the policy. Apple likewise separates
[performance baselines and deviation limits](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests).

## Measured baseline and limits

Calibration on September 6, 2026 at 12:25 a.m. EDT used five alternating pairs,
ten independent processes, and 25 post-warmup samples per operation/account
count on each side. Both production trees were the unchanged frozen revision.
The new benchmark source hash and all seven samples from every process are
committed in `scripts/usage-history-performance/calibration.json`. Its original
measurement policy is recorded separately from the subsequently adopted limits.
Re-evaluating those samples against the adopted policy passes.

The local calibration truthfully records `candidateDirty: true`: the new
benchmark, manifest entry, and documentation were uncommitted then. All
`CodexBarIOS` production sources matched the frozen revision, as checked before
the run and independently confirmed from the committed change:

```sh
git diff --exit-code 3395ee6094ce8e4199577f7ede493e3a50ee1269 \
  ea8eb7baec0e459f0403eb0d07b0fc01e4f21602 -- CodexBarIOS
```

The recorded benchmark SHA-256 identifies the benchmark source copied into both
builds. This is verified source equivalence for the measured workload, not a
claim of bit-identical binaries. The later [cold hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/34011866772)
used a clean checkout and passed on Apple M1 Virtual hardware with Xcode 26.6.
Its job took 4 minutes 50 seconds, including 54.11-second and 42.86-second Release
builds, within the 20-minute timeout.

The current benchmark explicitly casts the bounded account numbers to `Int32`
for `%02d`. This formatting correction sits outside the timed operations and
preserves all account IDs, fixture values, series work, and retained-data output.
The historical source hashes and timing observations remain unchanged.

| Accounts | Reference recording median, ms | Reference all-account series median, ms | Retained serialized bytes |
| ---: | ---: | ---: | ---: |
| 1 | 4.010 | 1.018 | 218,162 |
| 10 | 40.006 | 12.384 | 2,181,602 |
| 25 | 90.004 | 38.697 | 5,454,002 |

The latency columns are medians of the five process medians. They are diagnostic
Mac measurements, including JSON encoding and `UserDefaults.set`, not iPhone goals.
The largest median candidate/reference ratio was 1.0265. The largest individual
pair ratio was 1.0459, and the largest between-run CV was 8.06%. One recording
distribution had a 26.54% within-run CV; its full samples remain in the evidence.
The paired medians handled that observed burst without discarding it.

The maintained limits are:

- A median latency ratio of at most **1.25** for each operation and account
  count. This allows a 25% increase, over five times the largest observed
  positive paired deviation of 4.59%, while catching a sustained slowdown.
- A between-run CV of at most **15%** on both sides, below twice the largest
  measured control variation. Beyond this, the experiment cannot establish a
  pass. This is a measurement-quality threshold, not a latency allowance.
- Candidate serialized size no larger than the same-host reference maximum,
  with **zero bytes of positive steady-state growth** after warmup. All 47
  observations in every calibration process had exactly the sizes above.
  Constant-width values and timestamps, fixed per-account counts, and the
  canonical daily representation justify an exact retained-data budget.
  A deliberate persisted-schema expansion therefore needs reviewed evidence.

These thresholds are an initial measured regression policy. They are not a
claim that 90 ms of main-actor work is a good device experience. Device profiling
can inform a later optimization issue without changing this measurement-only
scope.

## Baseline maintenance

`scripts/usage-history-performance/baseline.json` owns the immutable revision
and limits. `calibration.json` next to it records the measured evidence. Schema
or fixture changes need a fresh calibration on both sides and review of expected
counts/series output. Toolchain changes compile both revisions with that same
toolchain, and retain the actual version in the report.

Change the frozen revision or resource limits only in an issue-linked PR that
explains the accepted behavior or cost, commits new raw distributions and
hardware metadata, and repeats the slowdown proof. Do not raise a limit merely
to make a regression green. A public API change that prevents the frozen source
from compiling is an explicit baseline maintenance task, not permission to skip
the gate.

The committed calibration and slowdown records declare the
`uniform-retained-state-v1` format. Each scenario stores all seven raw timings
for both operations. Its 47 byte-for-byte equal retained-state observations are
stored once as `retainedState` with `retainedObservationCount: 47`. This is
lossless compression of the observed records, not the runtime report schema.
Runtime artifacts retain the full `retainedStates` array.

Replay the committed evidence without rebuilding or taking new measurements:

```sh
python3 scripts/usage-history-performance/replay.py
```

The replay tool validates the declared format, expands every observed state,
then passes the reconstructed reports through the ordinary `validate` and
`evaluate` functions with the current policy. It must report calibration PASS
and recording regressions for all three account counts in the slowdown proof,
without noise findings. The policy tests exercise this path and reject invalid
compressed records. The original timing, hash, and dirty-state metadata are
preserved as historical measurements.
The same command also replays `repeatability-study.json`, including its failed
experiments. It requires the complete, unique experiment manifest, at least
three pairs per experiment, exact SHA-256 hashes of the expanded canonical JSON
reports, and agreement with every recorded verdict, finding and timing summary.
Derived floating-point summaries permit only `1e-12`
relative or absolute rounding differences. Raw samples, counts, verdicts and
policy thresholds receive no tolerance. A recorded inconclusive result remains
inconclusive.

## Prove slowdown detection

```sh
python3 scripts/usage-history-performance/run.py \
  --output /tmp/history-slowdown --prove-slowdown
```

This deliberately returns exit status 1. It inserts a 120 ms synchronous delay
inside `UsageHistoryStore.record` in the disposable baseline archive, builds that
candidate, then runs the ordinary paired gate against the untouched reference
binary. The normal checkout is unchanged. Count this as successful detection
only when `result.json` exists, `passed` is false, the findings include recording
`REGRESSION` results, and there are no `INCONCLUSIVE` findings. A compiler error,
fixture assertion, or infrastructure failure does not prove detection.

The deterministic failure-policy checks also run in the workflow:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_usage_history_performance.py' -v
```

The September 6, 2026 experiment completed all three paired runs and returned
status 1 with recording regressions at 1, 10, and 25 accounts, respectively
34.846x, 4.480x, and 2.543x. The one-account series measurement also exceeded the
budget, at 2.331x.
There were no inconclusive/noise findings. All fixture assertions and retained
budgets passed. `scripts/usage-history-performance/slowdown-proof.json` preserves
the complete timing distributions, metadata, and ordinary gate findings.

## Repeatability investigation

The September 6, 2026 study for
[issue #325](https://github.com/HemSoft/codexbar-ios/issues/325) preserves four
failed hosted attempts from three workflow runs. Each attempt failed only for
excessive between-run variation; none reported a latency or retained-data
regression. Their largest CVs were 31.19% and 19.65% for the two attempts of
[run 34046485812](https://github.com/HemSoft/codexbar-ios/actions/runs/34046485812),
35.05% for
[run 34051802297](https://github.com/HemSoft/codexbar-ios/actions/runs/34051802297),
and 20.06% for
[run 34054447047](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447047).
Each attempt produced six median ratios; across the four attempts they ranged
from 0.831 to 1.140. Replaying
all raw reports reproduces their original findings. The hosted metadata contains
hardware and toolchain versions but no process load or thermal observations,
so these artifacts cannot identify the cause of the hosted variation.

The historical local study used the M5 calibration host. Its recorded commit
revisions have matching production trees, but all eight local trials report a
dirty candidate worktree. No patch or content digest captured those dirty
inputs. The commit comparison therefore does not prove the actual build inputs
were unchanged. Retain these trials as historical timing observations, not as
proof of unchanged-code repeatability. The clean study below replaces that
missing evidence without deleting or relabeling any earlier samples.

The first plan declared three independent paired experiments followed by one
slowdown experiment. Two unrelated simulator startups and concurrent Swift
compilation occurred during the first two comparisons. Machine snapshots show
load averages reaching 99 and 141, alongside busy simulator and compiler
processes. Both comparisons were inconclusive. The third comparison passed.
The slowdown run detected recording regressions for every account count but
also had a 16.87% CV for one-account candidate series generation, so it was not
a valid slowdown proof. The snapshots do not establish the cause of that
series variation.

A second fixed block was declared after observing the startup bursts. Its
admission required nine snapshots 15 seconds apart over at least two minutes,
with one-minute load divided by logical CPU count at most 1.0, and no compiler
or simulator process using at least 10% CPU. All nine snapshots qualified;
normalized load ranged from 0.314 to 0.489. This is a documented local study
condition, not a changed timing threshold or a guarantee of host stability.
Admission covers only the start of the block.
The block declared three intended unchanged-code comparisons. A separate
once-only slowdown addendum was declared before any completed quiet comparison,
after the first comparison had started. Both declarations and their exact
sequencing remain in the evidence. The study stops after that fixed block.

Each comparison below contains three alternating pairs and six independent
processes. Ratios are the six median candidate/reference latency ratios, not
individual samples.

| Experiment | Gate result | Median ratio range | Largest run CV |
| --- | --- | ---: | ---: |
| unchanged-1 | Inconclusive | 0.833 to 0.980 | 64.69% |
| unchanged-2 | Inconclusive | 0.951 to 1.025 | 101.48% |
| unchanged-3 | PASS | 0.985 to 1.053 | 6.63% |
| slowdown | Regression and inconclusive | 0.980 to 34.442 | 16.87% |
| quiet-1 | PASS | 0.969 to 1.027 | 3.83% |
| quiet-2 | PASS | 0.990 to 1.021 | 12.28% |
| quiet-3 | Inconclusive | 0.991 to 1.075 | 20.03% |
| quiet-slowdown | Expected regression | 0.980 to 34.731 | 4.36% |

The admitted historical block reported two passes from three comparisons. Its
third candidate's one-account recording medians were 4.320, 4.470 and 6.442 ms;
series medians were 1.037, 1.100 and 1.594 ms. These yielded 19.05% and 20.03%
CVs. All corresponding reference medians remained between 4.020 and 4.417 ms
for recording and between 1.031 and 1.136 ms for series generation.
The last candidate started more than a minute after compilation and after the
preceding reference completed, so this was not the first process after a build.
Its recording timings declined across the 10-account scenario and returned to
the reference range by 25 accounts.

Two new Chrome renderer processes appeared in the snapshot immediately before
that last candidate. The machine also recorded compression and page-in activity
during the process. Captured snapshots showed no active compiler or simulator;
`pmset` reported that no thermal warning, performance warning or CPU power
status had been recorded. These observations do not identify a cause or prove
that the host was idle. The next diagnosis should measure a fixed series on a
host reserved for the entire experiment and compare per-scenario wall time,
CPU time and memory-pressure observations. This can distinguish early-process
host disturbance from a workload effect before changing the sampling design.

The final slowdown experiment returned status 1 with recording regressions of
34.731x, 4.423x and 2.394x for 1, 10 and 25 accounts. It had no inconclusive
findings, and all correctness and retained-data budgets passed. Slowdown
detection was reported, subject to the missing build-input evidence above. At
that checkpoint, three reliable unchanged-code experiments in one declared
block remained unproved. Selecting the three passing trials across the
two blocks would hide the failures. Keep the repeatability acceptance criterion
open and the workflow manual; this change does not claim to cure hosted noise.

`scripts/usage-history-performance/repeatability-study.json` stores every
hosted and local result, both plans, the addendum, source-equivalence proof,
machine snapshots and original metadata. All seven raw timing values remain
for every operation and account count. The existing
`uniform-retained-state-v1` representation compresses the 47 retained states
only after verifying that all are equal. Build and stderr log hashes identify
the full external artifacts. The historical calibration and slowdown records
remain unchanged.

The separate `repeatability-manifest.json` pins every original report digest and
expected verdict. Replay rejects coordinated edits to samples, embedded hashes
and results, including edits to warm-up values. Changes to this manifest require
review against the original artifacts; it is never regenerated during replay.

The issue branch later incorporated main commit
`ad8e89be9a4e8dc428c5b7fe1b2cb4cdca898cae`, which includes the Google quota
changes from PR #320. The study remains evidence about its recorded source
checkpoints; it does not measure that later application tree. The replay verifier
checks historical evidence without presenting it as a new benchmark run.

### Clean committed-input study — 2026-09-07

A new fixed plan declared three independent comparisons and one intentional
slowdown before starting any of them. All four invocations report
`candidateDirty: false` at commit
`2200edbc9be93f6a72c5f165888b601ebc8fe4d9`. The candidate production tree is
identical to frozen baseline `3395ee6094ce8e4199577f7ede493e3a50ee1269`.
Only the benchmark harness, manifest and evidence tooling were added. The
working tree stayed clean, and every tracked file hash was verified unchanged
after the final experiment. No simulator or device build was started locally.

The study retains the plan, all 24 raw reports in the existing lossless format,
their independent pinned hashes, the four original verdicts, machine snapshots,
artifact hashes and the build-input file manifest. Apply
`scripts/usage-history-performance/clean-build-inputs.patch` to the frozen
baseline to reconstruct the benchmark build inputs and runner. The patch hash, revision, file digests and trial metadata are independently
pinned in `clean-input-manifest.json`. Replay reconstructs and verifies all
111 build-input files from the baseline and rejects altered or dirty proof
metadata. The production-source diff is empty.

| Experiment | Result | Largest run CV |
| --- | --- | ---: |
| clean-1 | PASS | 3.1% |
| clean-2 | PASS | 4.1% |
| clean-3 | PASS | 12.4% |
| clean-slowdown | Expected regression | 4.3% |

The unchanged 15% variability limit and all latency, retained-state and
correctness limits remain enforced. The deliberate slowdown reports recording
regressions of 34.839x, 4.706x and 2.613x for 1, 10 and 25 accounts, plus a
one-account series regression. It has no inconclusive findings. These three
clean comparisons and the separate slowdown satisfy the local repeatability
criterion. They do not establish reliability on every hosted runner or justify
making the manual workflow an automatic gate.

Run the existing replay command to verify all 16 experiments, including every
historical failure. No failed sample was removed and no unchanged condition was
retried to obtain these three passes.

## Hosted startup admission, October 21, 2026

Build 6's first hosted comparison and its single unchanged retry were
inconclusive for one-account timings. The retry recorded one-minute load
declining from 9.64 to 1.98 on a three-CPU runner while its six measured
processes ran. This supports testing startup disturbance; it does not prove
the cause of every timing fluctuation. Both failed artifacts remain retained.

The runner now admits one fixed experiment after both binaries compile. It
requires nine consecutive observations spanning at least two minutes with
one-minute load divided by logical CPU count at most 1.0 and no compiler or
simulator process using at least 10% CPU. Admission has a 420-second deadline;
each process probe is bounded by the smaller of five seconds and the remaining
admission budget. No new probe starts after the deadline. Missing or malformed
observations fail. `host-admission.json` retains every observation and the
outcome, including the exact serializable invalid observation or an explicit
representation when a value cannot be encoded as JSON. Simulator runtime
children are included even when their executable is outside CoreSimulator.
A busy host resets only the admission streak, never a timing result.

Admission runs once. If it fails, no timing process starts. If admitted, the
existing three alternating pairs run with every sample and all latency,
variability, serialization and retention thresholds unchanged. Admission is
not a guarantee of stability for the rest of the experiment. Later noise
still fails the gate; no measurements are discarded or selected for a pass.
The manual workflow timeout and all automatic CI work remain unchanged.
Hosted verification of this adjustment is pending.
