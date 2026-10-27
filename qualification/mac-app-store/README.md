# Provisional native Mac qualification

Partial work for [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476), following the [platform plan](../../docs/2026-10-17-codexbar-pro-platform-plan.md). Franz authorized **Apple-local Pro and provisional native Mac qualification** on October 21, 2026. This does not select a shipping platform, authorize a paid desktop launch or promise shared Pro. The parent owns recording [#475](https://github.com/hemsoft-dev/codexbar-ios/issues/475). Keep #476 open.

This directory is disposable development tooling. It changes no iOS/watchOS target, app record, shared entitlement, CI workflow, release metadata or production account. Its independent `0.0.1`/`1` version has no relationship to the iOS release build or original-purchaser cutoff.

## Candidate and scope

| Item | Provisional candidate |
| --- | --- |
| Channel | Native Mac App Store, subject to a later shipping decision |
| Framework | SwiftUI window hosted by AppKit; Network loopback listener; Security Keychain |
| Minimum OS | macOS 14 compile target, not a qualified minimum supported runtime |
| Architecture | Universal arm64 + x86_64; x86_64 run under Rosetta 2 on air, not on Intel hardware |
| Owning repository | hemsoft-dev/codexbar-ios, this directory only |
| Local identity | `com.hemsoft.qualification.mac476`, deliberately separate from the shipping app |
| Usage | Fixed, visibly synthetic personal/work samples |
| Commerce | No checkout, sale, server, account linking or real purchase API |

## Reproduce locally

From the repository root on a Mac with Xcode installed:

```sh
./qualification/mac-app-store/build.sh
'qualification/mac-app-store/build/CodexBar Qualification.app/Contents/MacOS/CodexBarQualification' --self-test
open 'qualification/mac-app-store/build/CodexBar Qualification.app'
./qualification/mac-app-store/qualify-update.sh
./qualification/mac-app-store/qualify-portability.sh
# Optional team-identity signing, using the dedicated signing keychain:
./scripts/with-codexbar-keychain.sh env QUALIFY_PUBLISHER_IDENTITIES=1 \
  PUBLISHER_BUNDLE_SUFFIX=devsigned ./qualification/mac-app-store/qualify-portability.sh
```

`PUBLISHER_BUNDLE_SUFFIX` gives team-signed copies their own sandbox container.
Without it, a team-signed launch under an ID that an ad hoc build already used
blocks in sandbox initialization. See [RESULTS.md](RESULTS.md#portability-and-team-identity-rehearsal-october-27-2026).
Franz-owned Store steps are in [STORE-HANDOFF.md](STORE-HANDOFF.md).

`build.sh` uses Xcode explicitly, Swift 6 warnings as errors, the current host architecture and ad hoc signing. It creates a local `.app` inside ignored `build/`, with no dependency downloads. The developer-only StoreKitTest framework remains an Xcode runtime dependency. This bundle is not a distribution candidate. Closing the last window exits it.

The self-test runs **inside the ad hoc sandboxed app**. It checks outside-container write denial, account-specific Keychain create/read/update/delete, loopback HTTP, fragmented/oversized/incomplete HTTP framing, forged/duplicate state, unknown accounts, replay, expiry with terminal failure and immediate retry, cancellation, credential-save-before-connected state, navigation state and the synthetic restore reducer. A nonzero exit means failure. It creates fixture credentials under unique test-only services, seeds Work before model construction and removes only those test items afterward. Existing interactive fixture accounts are preserved. Deadline regressions use an injected scheduler fired only after listener readiness, with guarded URL/state extraction. They exercise the same attempt-bound expiry callback while asserting the app still schedules 120 seconds. Failed browser opening must immediately release the listener, clear busy, report failure and allow retry. The loopback closure check accepts only cannot-connect or connection-refused errors; timeout and transport-policy controls must fail that classifier.

For the native StoreKit runtime attempt, separate from the synthetic rehearsal:

```sh
./qualification/mac-app-store/test.sh
```

This is a standalone Xcode project, with a minimal AppKit-hosted XCTest target and an immutable result directory per run. The host does not initialize the fixture window, authorization or credentials. Its test action explicitly associates `Qualification.storekit`. It does not call the repository's iOS/watchOS tests. The checked-in project is generated reproducibly by `python3 qualification/mac-app-store/generate-project.py`. The StoreKitTest Objective-C header references a deprecated StoreKit 1 type; only imported Clang deprecation diagnostics are suppressed in this isolated project. Swift warnings remain errors.

The runner defaults explicitly to the installed `/Applications/Xcode_26.6.app/Contents/Developer`, Xcode 26.6 build `17F113`, qualified against air's macOS 26.6.2. It does not change `xcode-select`. Override `DEVELOPER_DIR` explicitly to diagnose another toolchain. Each run records Eastern start/finish times, toolchain/OS, source hashes, per-phase console logs, exit status and `ordinary.xcresult`, `prepare.xcresult`, `relaunch.xcresult` under a unique ignored `build/storekit-*` directory. Build caches are separated by Xcode build number. A persistent per-user machine-wide `flock` covers the complete ordinary, prepare and relaunch procedure across worktrees, protecting the shared StoreKit host identity and relaunch marker. The shell and descendants inherit the lock descriptor. The internal child flag must validate that inherited, already-held lock before any native or marker action. Lock files are never removed, stolen or aged out. Use this runner for native qualification, including from other worktrees. Do not invoke the shared native tests directly through Xcode while a procedure runs.

Run `python3 qualification/mac-app-store/test-exclusivity.py` from the repository root to test missing/forged descriptor rejection, full-procedure contention with shared resource stand-ins, stale timestamps, safe reuse of the retained inode and lock survival after wrapper termination. This regression performs no StoreKit mutation. Failures are never retried automatically, overwritten, skipped or converted to passes.

**Native local gate passed on Xcode 26.6.** The test buys the lifetime product through `SKTestSession`, requires an Xcode-environment transaction, waits for a verified `Transaction.currentEntitlements` entry, refunds through `SKTestSession`, waits for entitlement removal and verifies the same transaction's revocation date. The five-second bounded polling handles StoreKit's asynchronous database propagation; purchase errors and unverified transactions fail immediately. The runner also exercises the adapter default catalog path. It then seeds a purchase in a separate preparation invocation and verifies the same transaction ID from a different host PID before creating a new session or purchasing anything. Refund removes access in that fresh process. This is native evidence, separate from the synthetic window rehearsal.

The original unhosted Xcode 27.1 run failed with `SKInternalErrorDomain Code=3` and `notEntitled`. Hosting removed that symptom, but Xcode 27.1's purchase path then failed in the local Octane service with `ASOctaneSupportXPCService.TransactionError Code=3` and a purchase-configuration decoding error. Catalog association, bundle versions and sandbox/network-client test entitlements did not repair that toolchain/runtime combination. Xcode 26.6 succeeded locally. Preserve the failed receipts in [RESULTS.md](RESULTS.md); this does not claim Xcode 27.1 support or require any Store record, enrollment, profile, signing identity or Apple-account action.

The separate test host declares only App Sandbox and network-client access in `StoreKitTestHost.entitlements`; Xcode additionally injects debugging/test exceptions. These test entitlements never alter `Qualification.entitlements` or the separately built fixture app. There is no invented IAP entitlement. Apple's [entitlement guidance](https://developer.apple.com/forums/thread/799000) explicitly identifies `com.apple.developer.storekit` and `com.apple.developer.in-app-purchase` as nonexistent entitlements.

## Exercise the window and browser return

1. On Dashboard, choose **Connect fixture**. The app starts a listener bound to `127.0.0.1` before opening the browser. The OS chooses the port.
2. In the local authorization page, select Personal or Work fixture and approve. No provider is contacted. The app saves an independently keyed synthetic token before showing the account, activates its window and displays its fixed sample quota.
3. Connect the other fixture. In Settings, disconnect one and verify the other survives. No token entry/import is offered.
4. Try Cancel in the browser, cancel from the app, or wait past the two-minute callback deadline. Invalid, expired or replayed callbacks never configure an account. A timed-out attempt can be canceled and restarted from the window.
5. In Settings, choose **Restore synthetic purchases** before seeding, then **Seed synthetic lifetime**, then restore again. The rehearsal reads the lifetime product ID from the copied StoreKit catalog and reduces an in-memory verified receipt fixture. It cannot prove a StoreKit transaction or unlock a real product. It resets on process exit.

For a controlled browser harness, launch the executable with `--evidence`. This starts the same listener without opening the default browser and prints its fixture-only authorization URL plus window ID. Navigate a local browser tab to that URL and approve. `--settings` opens the Settings screen. Normal Connect always opens the default browser.

The listener accepts only GET fixture routes, allowlisted fixture accounts and a random, expiring, single-use state. The browser returns over the same loopback server, then the app activates itself. This proves that synthetic transport only. It does not establish OAuth registration, ASWebAuthenticationSession behavior, provider policy approval, PKCE/token exchange or production provider support. Those require the chosen provider's real integration and Franz's live account checks.

## Sandbox and credential boundary

The signed standalone bundle has exactly App Sandbox, incoming network and outgoing network entitlements. Incoming traffic is required for its loopback listener; outgoing access is required for the self-test HTTP client and is a candidate requirement for future provider requests. The entitlements do not themselves restrict traffic to loopback; this prototype's source constructs only loopback requests. It has no file-picker, file, application-group, keychain-group, automation or temporary-exception entitlement.

Keychain items use generic-password class, a qualification-specific service with a per-build namespace, separate account keys and `WhenUnlockedThisDeviceOnly` accessibility. Tokens are synthetic random bytes, never printed, written to preferences or placed in browser URLs. Tests prove account isolation within this app, not production cross-process ACL or team/keychain-access-group behavior. Ad hoc signing is insufficient evidence for that distribution boundary. Rebuilding generates a new fixture namespace because legacy Keychain ACLs can otherwise prompt after the ad hoc code identity changes. Same-binary relaunch can reuse its namespace; upgrade credential migration is not qualified. Authentication queries set a noninteractive LAContext, but this is not proof that every legacy Keychain ACL path suppresses interaction. No Keychain passwords or ACL changes were requested. Keychain access failure leaves the account disconnected.

Xcode's Debug test build may inject test-only get-task-allow and temporary exceptions. **Do not use its entitlements as sandbox evidence.** Inspect `build/signed-entitlements.plist` from `build.sh`; the runtime sandbox checks use that separately ad hoc signed bundle.

## Apple-local purchase and distribution limits

The local catalog copies the existing product IDs from the [Apple test catalog](../../StoreKit/CodexBarPro.storekit). It is a snapshot for qualification, not a second product catalog or a new price decision. The native test checks verified lifetime entitlements only. It does not port the complete [#464 service](https://github.com/hemsoft-dev/codexbar-ios/issues/464), subscription/grace/offline behavior or [#465 original-purchaser contract](https://github.com/hemsoft-dev/codexbar-ios/issues/465).

Apple's [platform record guidance](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms) requires one app record and the same bundle ID for universal purchase; separate app records cannot be merged. The qualification ID intentionally cannot demonstrate that sharing. Do not add a Mac platform to the real record as a trial. Once multiple platforms are approved, platform removal is constrained.

A lifetime IAP test transaction is not an original paid-iOS-app transaction. No synthetic or Xcode receipt qualifies as an original production purchaser. This Mac prototype does not apply the iOS build-number/date cutoff, infer purchase portability from install metadata or promise that an original iOS purchase restores on native macOS. Eligibility, original platform/version semantics, family proof and actual universal-purchase restore remain separate verification work after selection. Apple-local access stays the accepted scope; no cross-store grant is implemented.

The candidate update owner is the Mac App Store. `qualify-update.sh` seeds a private version-1 installed copy under `build/`, rejects a modified signature, ad hoc re-signs a version-2 candidate and uses Darwin atomic directory exchange to replace the existing copy and reverse that exchange for rollback. It checks version, version-specific resources, absence of the other version's resources and strict signatures on both sides before and after each exchange. This qualifies only the local filesystem exchange rehearsal, with no updater implementation. It does not exercise a Store update or prove publisher trust, receipt retention, rollback policy or App Review approval. The read-only signing inventory found Apple Development/Distribution identities, but no identity was used and no Mac distribution profile was qualified. App Store signing, record/platform configuration, upload, review, Store install/update and real Apple-account restore are **not run**. A direct-download updater is outside this route.

References checked October 21, 2026: [Apple sandbox configuration](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox), [SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession) and the platform-record guidance above. These describe tools and constraints; they do not prove this app is approved for distribution.

## Evidence and pending gates

See [RESULTS.md](RESULTS.md) for the measured pass/fail/not-run matrix and retained local artifacts. The partial PR must embed current-head screenshots through verified GitHub attachment URLs. Parent owns current-head review and merge. No automatic CI work is added, and the release-only iOS UI workflow must not be dispatched for this qualification.

All build products and media stay ignored. To remove the local prototype, quit it, delete this directory's `build/`, and remove only its `com.hemsoft.qualification.mac476` container if desired. Disconnect each fixture in Settings first to delete its Keychain item. Do not delete a shared keychain or any iOS app data.
