# Qualification results on air

Measured October 21, 2026, EDT. This is a partial, provisional qualification for [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476), not approval to ship. Apple-local Pro remains the accepted scope. See [README.md](README.md) for reproduction and limits.

Environment: Apple silicon air, macOS 26.6.2 `25G83`, Xcode 27.1 `27A9275`, Swift 6, arm64 runtime. The app's content area is 1040 × 680 points, with 1040 × 712 points including its title bar. Captures use the system dark appearance at 2× scale. The local browser viewport is 1280 × 800 pixels.

| Gate | Result | Evidence and limits |
| --- | --- | --- |
| Isolated local `.app` packaging and launch | PASS | `build.sh`; ad hoc bundle runs from ignored `build/`; no installation into Applications or Store install |
| Swift 6 compile with warnings as errors | PASS | Standalone `build.sh` log |
| Pinned SwiftLint 0.65.1 | PASS | Six qualification Swift files, zero violations; used the existing main checkout's resolved binary and this repository's root config |
| Signed sandbox configuration | PASS | `codesign --verify --strict`; inspected standalone signed entitlements contain exactly sandbox, network client and network server |
| Runtime sandbox boundary | PASS | Outside-container `/private/tmp` fixture write denied |
| Guided loopback authorization | PASS | Sandboxed HTTP self-test plus actual browser approval of Personal fixture and app return |
| Callback defenses | PASS | Forged/duplicate state, unknown account, expired attempt, replay and browser cancellation assertions |
| Secure account credential isolation | PASS | Keychain read/write/update/delete assertions for separate Personal/Work account keys; not production ACL qualification |
| Dashboard and Settings | PASS | Actual native window inspected through accessibility tree; Dashboard shows labeled sample usage after browser approval; Settings controls exercised |
| Same-build relaunch | PASS | Closed and reopened the unchanged ad hoc binary; Personal fixture remained connected through Keychain. Disconnected it afterward and verified removal |
| Synthetic restore rehearsal | PASS | Empty, verified lifetime, revoked, unverified and wrong-product fixtures; actual Settings empty and restored states captured |
| Native StoreKitTest runtime | FAIL | One XCTest executed, one failure; `SKInternalErrorDomain Code=3`, then `notEntitled`; no native restore/refund success claimed |
| Local signature tampering | PASS | Changed version metadata invalidated signature |
| Local replacement and rollback rehearsal | PASS | Ad hoc version-2 copy verified, staged replacement verified, restored version-1 copy verified; no Store update |
| Shell syntax and Python generator syntax | PASS | `bash -n` and `python3 -m py_compile` |
| Intel runtime, macOS 14 runtime | NOT RUN | Compile target is a candidate minimum, not a supported-runtime claim |
| Live providers, real quota, registered OAuth | NOT RUN | Synthetic-only transport; Franz owns live account checks |
| Original iOS purchaser, production AppTransaction, family/universal restore | NOT RUN | No portability or macOS cutoff assumption; qualification bundle differs from shipping identity |
| Publisher signing, Mac profile and cross-update Keychain ACL | NOT RUN | Read-only identity inventory only; no identity used or profile configured |
| App Store install, update, receipt preservation, review | NOT RUN | No record/platform mutation, upload, store account or publication |
| Complete iOS/watchOS gates and full UI release workflow | NOT RUN | Unchanged production targets; no CI dispatch or expansion |

`--self-test` finished with **22 PASS assertions and `RESULT 0 failures`**. Its synthetic results do not cover the failed native StoreKit gate. The native XCTest result bundle is `build/storekit-20261021-135517.xcresult`; `test.sh` intentionally remains a failing diagnostic on this environment rather than skipping or hiding the failure. The earlier hosted runner did not start tests and was interrupted; the unhosted runner provides the explicit final failure above.

## Retained evidence

Ignored `evidence/` contains `build.log`, `self-test.log`, `swiftlint.log`, `native-storekit.log`, `update.log`, Dashboard and empty/restored Settings PNGs, browser account-selection/return PNGs, and a six-second browser approval MP4. The MP4 records the browser segment only; native return and Settings are proved by the separate screenshots and accessibility inspection. No whole-desktop recording was captured, to keep unrelated desktop content out of the evidence.

Media is test data only. Upload with GitHub CLI `--attach` into the partial PR's `## Validation` section and verify the saved body contains GitHub attachment URLs. Local paths and this document do not substitute for the embedded PR evidence. If parent review changes visible behavior, recapture the affected states at the new head.

## Remaining acceptance criteria

Franz has authorized provisional Mac qualification, not a shipping choice. The selected-channel criterion remains open. The local window, fixture authorization, sandbox and credential-isolation criteria have bounded evidence above. Native restore, universal-purchase configuration, original-purchaser scope and real signing/Store updates remain unqualified. The synthetic rehearsal is useful for inspecting behavior but is insufficient to pass those gates. Keep [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476) open, use **Refs** in the PR and leave parent review/merge pending.
