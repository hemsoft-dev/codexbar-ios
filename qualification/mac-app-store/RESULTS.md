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
| Local replacement and rollback rehearsal | PASS | Ad hoc version-2 copy verified, staged replacement verified, restored version-1 copy verified; no Store update |
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
