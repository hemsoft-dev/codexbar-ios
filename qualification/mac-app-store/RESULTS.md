# Qualification results on air

Measured October 21, 2026, EDT. This is a partial, provisional qualification for [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476), not approval to ship. Apple-local Pro remains the accepted scope. See [README.md](README.md) for reproduction and limits.

Environment: Apple silicon air, macOS 26.6.2 `25G83`, Xcode 27.1 `27A9275`, Swift 6, arm64 runtime. The app's content area is 1040 × 680 points, with 1040 × 712 points including its title bar. Captures use the system dark appearance at 2× scale. The local browser viewport is 1280 × 800 pixels.

| Gate | Result | Evidence and limits |
| --- | --- | --- |
| Isolated local `.app` packaging and launch | PASS | `build.sh`; ad hoc bundle runs from ignored `build/`; no installation into Applications or Store install |
| Swift 6 compile with warnings as errors | PASS | Standalone `build.sh` log |
| Pinned SwiftLint 0.65.1 | PASS | Seven qualification Swift files, zero violations; used the existing main checkout's resolved binary and this repository's root config |
| Signed sandbox configuration | PASS | `codesign --verify --strict`; inspected standalone signed entitlements contain exactly sandbox, network client and network server |
| Runtime sandbox boundary | PASS | Outside-container `/private/tmp` fixture write denied with NSCocoaErrorDomain 513; only permission-denial errors pass |
| Guided loopback authorization | PASS | Sandboxed HTTP self-test plus actual browser approval of Personal fixture and app return |
| Callback defenses | PASS | Forged/duplicate state, unknown account, expired attempt, replay and browser cancellation assertions |
| Secure account credential isolation | PASS | Keychain read/write/update/delete assertions for separate Personal/Work account keys; not production ACL qualification |
| Dashboard and Settings | PASS | Actual native window inspected through accessibility tree; Dashboard shows labeled sample usage after browser approval; Settings controls exercised |
| Same-build relaunch | PASS | Closed and reopened the unchanged ad hoc binary; Personal fixture remained connected through Keychain. Disconnected it afterward and verified removal |
| Synthetic restore rehearsal | PASS | Empty, verified lifetime, revoked, unverified and wrong-product fixtures; actual Settings empty and restored states captured |
| Native StoreKitTest runtime | PASS, Xcode 26.6 only | Hosted native purchase, verified Xcode current entitlement, refund, entitlement removal and verified revocation all executed; four tests in three separate invocations, zero failures. Earlier failed receipts retained below; Xcode 27.1 remains unsupported in this measured combination |
| Local signature tampering | PASS | Changed version metadata invalidated signature |
| Local replacement and rollback rehearsal | PASS | Private installed version 1 atomically exchanged with signed version 2, then exchanged back; version-specific resource absence/presence and both signatures verified at each step; filesystem rehearsal only |
| Shell syntax and Python generator syntax | PASS | `bash -n` and `python3 -m py_compile` |
| Intel runtime, macOS 14 runtime | NOT RUN | Compile target is a candidate minimum, not a supported-runtime claim |
| Live providers, real quota, registered OAuth | NOT RUN | Synthetic-only transport; Franz owns live account checks |
| Original iOS purchaser, production AppTransaction, family/universal restore | NOT RUN | No portability or macOS cutoff assumption; qualification bundle differs from shipping identity |
| Publisher signing, Mac profile and cross-update Keychain ACL | NOT RUN | Read-only identity inventory only; no identity used or profile configured |
| App Store install, update, receipt preservation, review | NOT RUN | No record/platform mutation, upload, store account or publication |
| Complete iOS/watchOS gates and full UI release workflow | NOT RUN | Unchanged production targets; no CI dispatch or expansion |

`--self-test` originally finished with **22 PASS assertions and `RESULT 0 failures`**. The parent review fix adds all-split header framing, premature EOF and oversized-header checks; the updated run passes **27 assertions**, with zero failures. Those synthetic results are independent of the native XCTest result. The original native failure remains retained by the parent at `build/storekit-20261021-135517.xcresult`. The earlier fixture-app hosted runner did not start tests and was interrupted; the follow-up below uses a separate minimal AppKit host.

## Native StoreKit repair, October 21, 2026 EDT

All attempts ran on air, macOS 26.6.2 `25G83`, arm64. The follow-up branch began by cherry-picking the original qualification commit. No iOS/watchOS files, fixture UI, authorization, credentials, catalog, distribution identity, provisioning profile or Keychain configuration changed.

| Local attempt | Time EDT | Result and receipt under this directory |
| --- | --- | --- |
| Original unhosted target, Xcode 27.1 `27A9275` | 2:01 PM | FAIL, `notEntitled`; `build/storekit-20261021-140101.xcresult` |
| Minimal AppKit-hosted XCTest, Xcode 27.1 | 2:01 PM | FAIL, native purchase `unknown`, Octane transaction error 3; `build/storekit-20261021-140136.xcresult` |
| Explicit test-action catalog association | 2:01 PM | FAIL, same purchase error; `build/storekit-20261021-140155.xcresult` |
| Host bundle versions declared | 2:02 PM | FAIL, same purchase error; `build/storekit-20261021-140225.xcresult` |
| Test-only sandbox/network-client entitlements | 2:02 PM | FAIL, same purchase error; `build/storekit-20261021-140240.xcresult` |
| Same hosted target with installed Xcode 26.6 `17F113` | 2:03 PM | Native purchase succeeds; immediate entitlement assertion fails before database propagation; `build/storekit-20261021-140248.xcresult` |
| Direct native assertions with bounded entitlement polling, Xcode 26.6 | 2:03 PM | PASS, one test, zero failures; `build/storekit-20261021-140326.xcresult` |
| Final runner and host-only scheme, fresh Xcode 26.6 build cache | 2:04 PM | PASS, one test, zero failures, 1.235 seconds; `build/storekit-20261021-140408-mAoTGI/TestResults.xcresult` |
| Final source control run, Xcode 27.1, separate build cache | 2:04 PM to 2:05 PM | FAIL, same Octane purchase error, exit 65; `build/storekit-20261021-140441-MeUusq/TestResults.xcresult` |
| Switch back to Xcode 26.6, final source | 2:05 PM | PASS, one test, zero failures, 1.172 seconds, exit 0; `build/storekit-20261021-140539-YyEoT4/TestResults.xcresult` |

The final test requires an empty starting entitlement set, an actual `SKTestSession.buyProduct` result with the lifetime product ID and `.xcode` environment, one native session transaction, a verified lifetime entry in `Transaction.currentEntitlements`, successful `refundTransaction`, absence from current entitlements, and a verified latest transaction with the original purchase ID and a non-nil revocation date. It never substitutes the synthetic reducer or skips a failing native call.

The evidence supports three repairs: run inside an application test host, use the locally compatible Xcode 26.6 StoreKitTest runtime, and wait for asynchronous transaction-database propagation. Xcode 27.1's hosted failures include local Octane logs saying `Failed to decode purchase configuration`, Cocoa errors 4864/3840. The exact private wire-format incompatibility is not proven; changing only the toolchain allowed purchase to execute. Explicit association and test entitlements remain declared in the reproducible generator, with no changes to the fixture app's signed sandbox boundary. This is a local Xcode test qualification, not a production Store restore or an original-iOS-purchaser proof.

The follow-up receipts above live in the isolated air worktree `/Users/home/.t3-server/worktrees/codexbar-ios/t3-d52b8cfa/qualification/mac-app-store/`. They are ignored artifacts and are not transported by cherry-picking the source commit. Keep that worktree until the parent has copied the receipts. Earlier console logs are copied to `evidence/native-storekit/`; final runner directories contain their own logs and environment records. The final test source passed three times on Xcode 26.6, including before and after the Xcode 27.1 control. Strict pinned SwiftLint reported zero violations in both changed Swift files, and shell/Python syntax and deterministic project regeneration checks passed.

## Retained evidence

Ignored `evidence/` contains `build.log`, `self-test.log`, `swiftlint.log`, `native-storekit.log`, `update.log`, Dashboard and empty/restored Settings PNGs, browser account-selection/return PNGs, and a six-second browser approval MP4. The MP4 records the browser segment only; native return and Settings are proved by the separate screenshots and accessibility inspection. No whole-desktop recording was captured, to keep unrelated desktop content out of the evidence.

Media is test data only. Upload with GitHub CLI `--attach` into the partial PR's `## Validation` section and verify the saved body contains GitHub attachment URLs. Local paths and this document do not substitute for the embedded PR evidence. If parent review changes visible behavior, recapture the affected states at the new head.

## Remaining acceptance criteria

Franz has authorized provisional Mac qualification, not a shipping choice. The selected-channel criterion remains open. The local window, fixture authorization, sandbox and credential-isolation criteria have bounded evidence above. Local native lifetime entitlement restoration, including a fresh host process reading the same transaction ID, and refund are now qualified on Xcode 26.6. Universal-purchase configuration, original-purchaser scope and real signing/Store updates remain unqualified. The synthetic rehearsal is useful for inspecting behavior but is insufficient to pass those gates. Keep [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476) open, use **Refs** in the PR and leave parent review/merge pending.

## Parent review fixes

The loopback receiver now accumulates bounded HTTP headers before parsing. The
shared framing component is tested at every split point and rejects premature
EOF and oversized input; normal browser authorization is still exercised through
the actual receiver. The browser-page assertion checks both its generated heading
and its existing account-selection paragraph.

The native adapter resolves its default catalog from its defining bundle, which
is the test bundle in the hosted XCTest context. A second native test calls the
default `prepare()` path and exercises adapter purchase, restore and refund. The
parent's updated run on air completed October 21 at 2:24 PM EDT with **two native
tests, zero failures**; receipt:
`build/storekit-20261021-142450-99Ghn8/TestResults.xcresult` in the parent
qualification worktree. The earlier raw SDK checks remain in the other test.


The next review required a fresh-process restore and a specific sandbox denial.
At 2:32 PM EDT on October 21, the final runner passed two ordinary native tests,
one separate purchase-preparation test and one restore test in another host PID.
The fresh host reads the same verified transaction before creating a new session
or buying anything, then refunds it and observes access removal. Receipts are
`build/storekit-20261021-143243-lLSzxL/{ordinary,prepare,relaunch}.xcresult`.
The first split-run attempt used incorrect target selectors, so all four methods
ran together and the different-PID assertion failed. That failure remains in
`build/storekit-20261021-143206-sVmwxu/ordinary.xcresult`; selectors now name the
actual StoreKitQualificationTests target. The source-hash record includes
Restore.swift. The sandbox run observed NSCocoaErrorDomain 513; unrelated write
errors fail the assertion. Pinned SwiftLint passed with zero violations in 281
files. Standalone build and all 25 assertions passed.


The next current-head review found that a late browser request left the model
waiting after expiry. The receiver now clears the attempt and URL, cancels the
listener and reports failure. Two assertions verify that busy clears, the expiry
message appears and Connect immediately starts a fresh state. Cancellation is
then exercised on that new state rather than the already expired attempt.


The evidence manifest also hashes `test.sh` itself, so retained native receipts
identify the selectors, phase order, toolchain default and failure handling that
produced them. This changes evidence provenance only, not app or test behavior.

## Bounded authorization review repair, October 21, 2026 at 3:18 PM EDT

Both connected Codex findings at `18df7ea7a26fc4bf10199cd9579a1e84301b8e9c`
are addressed in the standalone qualification app. A cancellable task starts with
each attempt and expires it without any browser request. The default remains
120 seconds. Expiry, listener errors, completion and cancellation clear the
pending attempt, URL and listener; expiry reports failure so the model clears
busy. Timer, listener-state and connection-receive callbacks verify attempt
identity before touching current state.

Self-tests use a fresh, test-only Keychain service and seed Work before model
initialization, proving restored credentials survive cancellation unchanged.
They never remove the interactive app's persisted fixture accounts. Only items
created under the test services are removed afterward.

Current standalone build passes Swift 6 warnings-as-errors compilation, ad hoc
signing and strict signature verification. The sandboxed self-test passes
**36 assertions, zero failures**, including no-request timeout and listener
closure, explicit and browser cancellation, completion, replacement-attempt
protection and preexisting Work/Personal credential preservation. Timeout tests
inject 0.15 seconds through the constructor; ordinary app construction retains
120 seconds.

The old-source control used Authorization.swift from the reviewed head with only
a constructor/timeout seam added so current tests could compile. It also restored
the reviewed cancellation assertion with Work already present. It built and
finished with **five failures**: the old Work-absence assumption, no-request
cleanup, listener closure, completion URL cleanup and replacement expiry.
The passing cancellation-preservation assertions in that control confirm actual
stored accounts were preserved. This is an adapted old-source control, not an
unmodified checkout execution. Its temporary source and binary remain under
`build/.review508-old-source/`.

Retained ignored logs under `evidence/`:
`review508-build.log`, `review508-self-test.log`,
`review508-old-source-build.log`, `review508-old-source-self-test.log`,
`review508-pinned-lint.log` and `review508-syntax-diff.log`.
The canonical pinned SwiftLint package-plugin command passes with zero
violations. Shell/Python syntax and diff-whitespace checks pass.
The initial direct lint invocation failed to load SourceKit with the default
developer directory, and forcing only the root config reported 56 unchanged
test-file violations by bypassing nested configs. Both failed logs are retained
as `review508-swiftlint.log` and `review508-swiftlint-xcode.log`; the corrected
canonical command explicitly selects Xcode and honors repository configs.

No native StoreKit source changed and no native StoreKit tests were rerun.
All exact prior procedure, toolchain, result-bundle and source-hash provenance
above remains historical evidence. This repair does not renew that evidence,
qualify live providers, prove production Store behavior or supply current-head
UI media. Parent owns current-head review, thread resolution and UI evidence.


## Five connected-review findings, October 21, 2026 at 3:34 PM EDT

The five findings on `49e9b2e836d0240d7010fcff4a34e369e37b0868` are repaired
in this existing worktree. All evidence below is local to air at
`/Users/home/.t3-server/worktrees/codexbar-ios/t3-a0ba4401/qualification/mac-app-store/`.
Earlier failure logs and receipts remain intact.

`test.sh` now acquires one persistent per-user machine-wide kernel lock before
any native phase or marker action, retaining it through all three invocations.
The protected resources are this user's shared StoreKit host state and relaunch
marker. The lock inode is checked for ownership, file type, hard links and
replacement, and is never removed or stolen based on a timestamp. Both shell
and descendants inherit its descriptor. The internal child flag verifies an
already-held inherited lock and independent-opener exclusion before proceeding.

`test-exclusivity.py` passes four grouped regressions. Direct child invocation
with a missing FD or a forged unlocked FD to the actual lock inode is rejected.
Two independent working directories contend across all three phases, asserting
that shared marker and transaction-state stand-ins retain their own identity.
An old timestamp on the held lock does not admit the contender, and the same
leftover inode is reused without deletion. Killing the wrapper with SIGKILL
leaves the descendant shell's lock held, demonstrated by an independent
nonblocking acquisition failure and a subsequent successful inherited-lock
check. No StoreKit reset is performed by this regression.
Log: `evidence/review508-r2-lock-final.log`.

Fresh native evidence for the final runner and lock helper is
`build/storekit-20261021-153144-itbXQr/`. Xcode 26.6 `17F113` ran all four
native tests in three invocations with zero failures, October 21 at 3:31 PM EDT.
Two more complete native procedures were then launched simultaneously. They
serialized from 3:33:14 to 3:33:24 PM EDT and from 3:33:24 to 3:33:32 PM EDT,
each passing all four tests, including matching the prepared transaction ID in
a fresh host before refund. Their directories are
`build/storekit-20261021-153314-zlezks/` and
`build/storekit-20261021-153324-m1GpcX/`.
Each contains `{ordinary,prepare,relaunch}.xcresult`, per-phase logs and an
`environment.txt` with hashes for the runner, lock helper, project generator,
Restore.swift, native tests, host, host entitlements, catalog, project and
scheme. All manifests match the final native inputs. Combined native console
logs are `evidence/review508-r2-native-final.log` and
`evidence/review508-r2-native-contend-{1,2}.log`.
The earlier successful interim run, before strengthening inherited-lock
validation, remains in `build/storekit-20261021-153035-1pNmHW/`; it is not the
final-procedure evidence.

Authorization retains its attempt-bound timer, identity guards, cancellation
cleanup, unique credential services and seeded Work-account preservation.
Deadline tests inject a scheduler and trigger the actual attempt expiry callback
after listener readiness. They deliberately invoke obsolete callbacks after
cancel, browser cancel, completion and replacement, without 150-millisecond
startup races or forced URL/state unwraps. The app's default scheduler still
sleeps for the requested 120 seconds, and the regression asserts that default
value. Listener startup has a bounded 15-second wait rather than two seconds.
The canceled URL is requested with a five-second client timeout, but only an
exact cannot-connect or connection-refused error passes. Timeout and transport
policy errors are explicitly rejected. A failed injected browser opener must
clear busy, release the listener/URL, report the launch failure and permit retry.

The final sandboxed self-test produces **42 PASS lines and RESULT 0 failures**,
including the informational window-size line. The original expired-attempt,
preexisting account, HTTP framing, secure storage and synthetic restore checks
remain. `evidence/review508-r2-build-final.log` proves Swift 6 warnings-as-errors
compilation, ad hoc signing and strict verification;
`evidence/review508-r2-self-test-final.log` records the result.

Two adapted old-behavior controls each fail exactly one regression and exit 1.
Restoring the reviewed opener-result disregard while retaining the injected
opener seam fails immediate cleanup. Replacing exact transport-error
classification with blanket acceptance fails rejection of unrelated errors.
These are targeted behavioral controls, not unmodified old checkouts. Their
sources and binaries remain in `build/.review508-r2-{old-opener,blanket-error}/`;
logs are `evidence/review508-r2-{old-opener,blanket-error}-verified.log`.
The earlier 36-pass run and adapted five-failure control above remain historical.

The updated local replacement rehearsal starts with signed version 1 actually
present at `installed.app`. Both versions have distinct signed resources.
Darwin `renamex_np(RENAME_SWAP)` atomically exchanges the existing installed
bundle and version-2 candidate, then reverses that operation for rollback.
Version, resource contents, absence of stale resources and strict signatures
are checked on both paths before and after each exchange. It passes in
`build/update.ME0f9g/` against the final standalone build, with log
`evidence/review508-r2-update-final.log`. The earlier passing rehearsal remains
in `build/update.g3D7uj/` and `evidence/review508-r2-update.log`.
This is only a private local filesystem rehearsal, not a Mac App Store update,
receipt-preservation proof, publisher trust proof or updater implementation.

Canonical pinned SwiftLint, shell/Python syntax, deterministic project generation,
manifest verification and diff-whitespace checks pass. Final logs are
`evidence/review508-r2-pinned-lint-final.log` and
`evidence/review508-r2-syntax-diff.log`.
The first compile failed because the test callback needed `@escaping`; its log
remains `evidence/review508-r2-build.log`. Initial control runs recorded their
expected failures, but a shell harness then tried to assign zsh's reserved
`status` variable. The verified Python harness above records their actual exit
codes without that error; original control logs remain preserved.

No production target, automatic CI, other machine, paid API, production
credential, App Store record, PR body or media changed. Live providers, publisher
signing, Store delivery and purchase portability remain unqualified. Parent owns
current-head review, thread resolution, UI evidence and merge.


## Readiness ownership and toolchain-independent lock tests, October 21, 2026 at 3:48 PM EDT

Repairs for connected Codex findings `4341194342` and `4341194363` are scoped to
issue #476 and PR #508 in the existing air worktree. The model now gives each
connect invocation an identity. Readiness polling, browser opening, status,
result delivery, terminal timeout and catch cleanup require that identity.
Cancel, replacement, successful completion and failure invalidate it. An older
invocation's timeout or task cancellation cannot cancel its replacement.

A manual continuation rendezvous supplies delayed readiness without starting a
listener or sleeping in the new regressions. It exercises cancellation before
URL readiness, immediate retry, stale result callbacks, stale startup errors,
old task cancellation, replacement at the final polling boundary, success and
failure before readiness, and cleanup for current task cancellation. Existing
real-loopback checks remain intact. The default readiness bound remains 750
polls at 20 milliseconds and the independent attempt deadline remains 120 seconds.
The exact connection-error classifier, failed-opener cleanup, account isolation,
42 earlier PASS lines and atomic replacement implementation remain intact.

`evidence/review508-r3-build.log` records Swift 6 warnings-as-errors build,
ad hoc signing and strict signature verification. The sandboxed standalone
self-test reports **51 PASS lines and RESULT 0 failures**, including the
informational window-size line, in `evidence/review508-r3-self-test.log`.
`evidence/review508-r3-pinned-lint.log` records zero violations from canonical
pinned SwiftLint. Shell syntax, Python AST parsing and diff whitespace pass in
`evidence/review508-r3-syntax-diff.log`.

The lock regression supplies a temporary existing dummy developer directory to
the actual `test.sh --exclusive-child` entry point. Missing and forged inherited
FDs must fail at that guard; temporary xcodebuild/xcrun traps prove no native
command is reached. Both an unset DEVELOPER_DIR and a missing qualified path
pass all four prior grouped lock regressions, preserving contention, stale inode,
forged descriptor and surviving-child protection. Logs are
`evidence/review508-r3-lock-{unset,missing}-xcode.log`. No qualified Xcode path
is inspected or used by these tests.

An adapted old-behavior control removes the final-timeout and catch identity
guards while retaining the polling guard and test seams. It exits 1 with three
regression failures in `evidence/review508-r3-old-polling-verified.log`.
Sources and binary remain in `build/.review508-r3-old-polling/`. Earlier control
attempts also removed the polling guard, leaving the manual canceled-readiness
rendezvous waiting; they were terminated and are not passing control evidence.
Their logs remain as `evidence/review508-r3-old-polling{,-interrupted}.log`.

Native StoreKit evidence is unchanged historical provenance at
`082965b0b2f306fc6fa4219baa1caf819e1faba1`: three complete procedures, four tests
per procedure, 12 tests total with zero failures, in the three final directories
listed above. No new native run is claimed. `test.sh`, lock helper, native
sources, catalog, generated project and scheme are unchanged by this repair.
The existing atomic replacement rehearsal remains historical evidence too.

No main-worktree changes, other machines, paid APIs, production credentials,
CI dispatches, review requests, thread resolutions, App Store work, PR body or
media changes were performed. Parent owns current-head review, UI evidence,
checks and merge. Live provider and Store delivery limitations remain unchanged.

## Runner logging failure repair, October 21, 2026 at 3:55 PM EDT

Connected Codex finding `4341288280` is addressed. Each native phase captures
both pipeline statuses atomically before another command can overwrite them.
A failed Xcode command remains the primary exit status even when logging also
fails. A logging-only failure fails the procedure and stops later phases, with
the tee status reported on stderr. Final metadata errors are reported and fail
an otherwise successful run while preserving an existing phase failure.

`python3 qualification/mac-app-store/test-runner-pipeline.py` passes five
controlled cases through the actual runner pipeline in temporary directories:
Xcode/tee exits 0/74 stop after one phase with exit 74; 65/74 stop after one
phase with exit 65; 0/0 complete three phases; a final metadata exit 73 preserves
a prior Xcode exit 65; a metadata-only failure exits 73 after three phases.
Fake commands consume all input and use explicit exit codes. Only the lock
checker is replaced in the isolated copy. No real StoreKit is used by these
controls. The unmodified reviewed `test.sh` at `e2c99d2` fails the logging-only
regression, returning 0 and continuing instead. Log:
`evidence/review508-r4-pipeline.log`.

Fresh native validation on Xcode 26.6 build `17F113` passed all four native tests
in three invocations from 3:55:13 to 3:55:23 PM EDT. Retained evidence is
`build/storekit-20261021-155513-C57ZUn/{ordinary,prepare,relaunch}.xcresult`,
phase logs and environment manifest. All ten manifest hashes match the final
runner and native inputs. Combined log: `evidence/review508-r4-native.log`.
The initial manifest verifier incorrectly expected eleven entries; after
correcting that count, all ten existing manifest entries passed verification.

Canonical pinned SwiftLint passes with zero violations in 301 files in
`evidence/review508-r4-pinned-lint.log`. Shell syntax, Python AST parsing,
manifest verification and diff whitespace pass in
`evidence/review508-r4-syntax-manifest-diff.log`. App, Swift and standalone
checks are unchanged, so the prior 51-assertion result remains historical and
was not rerun. Prior controls and failure receipts remain intact in this
worktree. No automatic CI, production Store, other machine or paid API was used.
Parent retains review, thread-resolution, CI, UI-media and merge ownership.

## Self-contained regression and clean packaging repair, October 21, 2026 at 4:11 PM EDT

Connected Codex findings `4341431288`, `4341431295` and `4341431305` on
`102d4bcd55b80c4d91f2de4a00cee1447b6b9c25` are addressed in the existing
issue #476 / PR #508 qualification worktree on air.

The pipeline regression constructs the old failure mode from the current runner
by replacing only its phase-status capture/tee handling with Xcode-only status
capture. It no longer runs Git or requires an intermediate commit. Five current
cases pass, preserving Xcode-versus-tee and final-metadata failure precedence.
The constructed old-behavior control exits 0 instead of required exit 74 and is
rejected. This is a targeted behavioral control, not an unmodified old checkout.

`build.sh` removes only `build/CodexBar Qualification.app` before creating its
contents and refuses a symlinked build directory. Sibling ignored build and
evidence directories remain intact. `test-packaging.py` uses fake compilation
and signing to test removal of seeded nested obsolete resources, retention of
sibling evidence and refusal of a redirected build directory. Its constructed
mkdir-only control fails because the obsolete file survives. The actual native
standalone build was also seeded with an obsolete nested resource and an
obsolete top-level Contents file; both disappeared from the freshly signed
bundle. The retained 3:55 PM native receipt remained present.

Both assertion-based Python regressions reject optimized execution before any
PASS output or subprocess work. The generated lock worker independently rejects
optimization too. `python3 -O <script>` and `PYTHONOPTIMIZE=1` runs exit nonzero
with an explicit error. Executable temporary copies were also invoked directly
with `PYTHONOPTIMIZE=1`, and the extracted generated worker was tested under
both optimization forms. A bounded unguarded-assertion control demonstrates the
old risk: a deliberately failed invariant fails normally but prints misleading
success under `-O`. Optimized execution is deliberately unsupported, not a
passing qualification run. The new packaging test uses explicit exceptions.

Commands run from the worktree root, all exit 0 unless explicitly described as
expected rejection above:

- `python3 qualification/mac-app-store/test-runner-pipeline.py`
- `python3 qualification/mac-app-store/test-exclusivity.py`
- `python3 qualification/mac-app-store/test-packaging.py`
- Copied those scripts and their shell/lock dependencies with `shutil.copy2`
  into a fresh temporary directory without `.git`, then ran each Python script
  with that directory as cwd. All controls pass without history or repository
  metadata; this also removes dependence on shallow-clone history.
- `qualification/mac-app-store/build.sh`: Swift 6 warnings-as-errors, ad hoc
  signing and strict signature verification pass after actual contamination.
- `'qualification/mac-app-store/build/CodexBar Qualification.app/Contents/MacOS/CodexBarQualification' --self-test`:
  **51 PASS lines and RESULT 0 failures**.
- `qualification/mac-app-store/qualify-update.sh`: seeded version 1, signature
  tamper rejection, atomic replacement and rollback pass on the rebuilt bundle;
  retained directory `build/update.rItP0f/`.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift package plugin --allow-writing-to-package-directory swiftlint lint --reporter xcode .`:
  pinned lint passes with zero violations in 301 files.
- `/bin/bash -n` for all qualification shell scripts, `ast.parse` for all
  qualification Python scripts, SHA-256 verification of all ten historical
  native manifest inputs, and `git diff --check`: pass.

Ignored logs under `evidence/` are `review508-r5-build.log`,
`review508-r5-self-test.log`, `review508-r5-update.log`,
`review508-r5-pinned-lint.log`, `review508-r5-pipeline.log`,
`review508-r5-lock.log`, `review508-r5-packaging.log`,
`review508-r5-optimized-no-git.log`, `review508-r5-optimization-controls.log`
and `review508-r5-syntax-manifest-diff.log`.

The October 21 3:55:13–3:55:23 PM EDT four-test native run at `102d4bcd`
remains historical evidence in `build/storekit-20261021-155513-C57ZUn/`.
All ten manifest inputs still match; the native runner, lock implementation,
compiled native sources, catalog, project and scheme are unchanged. No native
rerun is claimed. Standalone Swift sources and their 51 checks are unchanged.
Only isolated qualification packaging, Python regressions and these results
changed. Root main, shipping source, automatic CI, other machines, paid APIs,
App Store Connect, PR media and body remain untouched. No review request,
check polling, thread resolution or merge was performed. Parent owns fresh
current-head review, checks and UI evidence. Live-provider, publisher-signing,
Store-delivery and purchase-portability limitations remain unchanged.

## Signature baseline repair after complete thread audit

The parent found previously unhandled finding 4341431276 in the full thread inventory. Earlier metadata-tamper evidence was confounded by the version-specific resource added before signing. `qualify-update.sh` now signs the complete version 2 candidate and requires strict signature verification before changing only CFBundleVersion. The actual run passes that baseline, rejects the plist mutation, then re-signs and passes seeded replacement and rollback. Receipt: `build/update.KvU9Cw/`; log `evidence/review508-r6-update.log`. A temporary copy of the old runner with the same pre-mutation verification fails with exit 61 before changing the plist (`evidence/review508-r6-old-control.log`). Historical old tamper results do not isolate metadata integrity.

Only this local rehearsal procedure and results changed. Shipping source, standalone Swift checks, native StoreKit inputs and automatic CI are unchanged. The 51 standalone checks at 0f1aba3 and four native tests at 102d4bc remain historical evidence; no rerun of those suites is claimed. Store delivery, publisher trust and receipt preservation remain unqualified.
