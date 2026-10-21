# Apple-local synthetic Pro states

Local fixture work for [#477](https://github.com/hemsoft-dev/codexbar-ios/issues/477). Franz's October 21, 2026 clarification selects Apple-local per-store Pro and provisional native Mac qualification. The parent owns the decision record in [#475](https://github.com/hemsoft-dev/codexbar-ios/issues/475). This prototype changes no product, project, package, production code, store configuration or CI workflow.

The Apple-local contract comes from [#464](https://github.com/hemsoft-dev/codexbar-ios/issues/464), the [Apple plan](../../docs/2026-10-16-codexbar-pro-plan.md) and the existing [resolver](../../CodexBarIOS/Services/ProEntitlementResolver.swift). The [platform plan](../../docs/2026-10-17-codexbar-pro-platform-plan.md) supplies the scenario inventory, not approval for sharing. No account, shared entitlement service, shared lifetime lease or website checkout is part of the selected product boundary. Native Mac is not qualified by these fixtures, and no iOS-to-Mac universal-purchase promise is made.

## Run locally

Requires Python 3.10 or newer, standard library only. From the repository root, run the Apple-local acceptance suite:

```sh
python3 -B -m unittest discover -s prototypes/pro-state -p test_apple_local.py -v
```

Run the separately excluded hypothetical experiments only when useful for research:

```sh
python3 -B -m unittest discover -s prototypes/pro-state -p test_hypothetical_shared.py -v
```

The first suite has 10 tests with parameterized boundary and event-order cases. The second has 16 tests. Both passed locally on air on October 21, 2026. No hosted validation was dispatched. These commands create no receipts, credentials, files, network traffic or charge. `charges` counts simulated purchase attempts only. It cannot establish payment settlement or a merchant's actual charge count.

## Selected Apple-local behavior

`Client.sync(ledger, None, now)` calculates one access result from independently verified source grants. An Apple-local client sees only Apple chains in its synthetic verified store identity. Neither a billing account nor a region list is needed. A desktop client receives no transferred access and cannot invoke the simulated Apple purchase path.

| State | Apple-local result |
| --- | --- |
| Pending | Free; suppress another attempt. |
| Trial, active, renewal | Pro before signed expiry. |
| Canceled but paid | Pro through paid-through expiry; cancellation is not a refund. |
| Grace | Pro through verified grace end. |
| Hold / billing retry without grace, explicit expiry | Free after reconciliation; suppress renewal overlap while billing remains unresolved. |
| Refund / revocation | Remove only that source chain immediately on reconciliation. |
| Lifetime / qualifying original purchaser | Unlimited local offline access until observed verified revocation. |
| Unverified or redirect-only result | No grant and no successful attempt reconciliation. |

A cached timed decision ends at the signed expiry or verified grace end plus exactly three days. Access uses an exclusive deadline. At the deadline it is free. Successful authoritative refresh at expiry denies access immediately. First launch and reinstall have no cached proof; native verified restore can recover access without an account or a new charge. Saved client checkpoints retain the original deadline and reject observed time rollback. Local relaunch never recalculates a deadline. A local store identity switch replaces its verified chain set and reconciles before publication.

`checkout_apple_local` is an in-memory attempt counter, not a StoreKit adapter. It requires reconciliation, suppresses access already owned, pending/hold/grace and unresolved renewing subscriptions, and reuses the pending attempt. Only explicit synthetic adapter confirmation can clear an attempt. It cannot cancel renewal, charge money or enable commerce. No automatic replacement purchase follows a refund. Family access requires its own qualifying proof; an unproven family member receives no invented grant and no automatic charge.

## Acceptance coverage and exclusions

| Original #477 criterion | Evidence at the selected boundary | Excluded or still pending |
| --- | --- | --- |
| Source grants and one Pro state | `test_all_states_without_account`, `test_refund_reconnect_and_distinct_valid_lifetime`; all 12 states, multiple independent chains | Real receipt authenticity and native SDK behavior require the existing Apple service and sandbox gates. |
| Apple-to-desktop subscriber, original buyer, refund | `test_account_free_purchase_restore_and_no_desktop_transfer`, `test_original_buyer_and_unproven_family_no_charge`, refund tests; Apple unlocks, desktop stays free, one initial simulated attempt or zero restore/refund attempts | Shared unlock is explicitly unsupported. Desktop checkout is disabled. Native Mac requires separate qualification. |
| Duplicate/unordered/stale events, account binding, switch/reinstall/deletion | All six permutations plus duplicate replay and stale denial; `test_apple_store_identity_switch_and_restore`, restore fixture | Shared purchase-chain/account binding and account-deletion recovery are excluded because there is no shared account service. Native store identity switching remains an integration gate. |
| Offline deadline, reconnect, no proof, rollback | Boundary offsets -1/0/+1 for trial/active/canceled/grace; unlimited local permanent grants; serialized checkpoint relaunch, rollback, revoked reconnect | No shared lease is approved or needed. Fixtures do not prove tamper-resistant cache, secure elapsed time or reboot continuity. |
| Suppress redundant checkout; reject forged return | Pending/renewing/hold/grace and unverified/forged/redirect fixtures; exact attempt counts and retry equality | Cannot prevent independent purchases with unlinked store identities or external merchant settings. No cross-merchant identity correlation exists. |
| Exclude provider data; retention/deletion | Strict event allowlist, fixed error codes, sentinel rejection; no account binding in Apple suite | No production billing backend or retention policy is introduced. See privacy boundary below. |
| Source adapters, policy/region gating, sandbox gates | Adapter contract and gates below; all non-Apple checkout paths remain unreachable with policy `None` | No commercial program, seller, region or sharing approval is inferred. |

The issue remains open. This PR supplies the independent synthetic portion and documents unsupported sharing explicitly; the parent owns disposition of the narrowed acceptance criteria and all final review/merge decisions.

## Adapter and privacy boundary

`Event.fixture` accepts a strict schema with source, fixture chain identifier, ordered revision, state, signed expiry, optional grace end, renewal flag and verification time. Identifiers must be numeric `fixture-…` values. Extra metadata, arbitrary strings in typed fields and raw errors cannot enter billing payloads. Error logs contain fixed codes only. No provider credentials, account labels, balances, usage or history are read or serialized. Client cache JSON is a trusted synthetic checkpoint used for replay testing, not an untrusted or authenticated production format.

The Apple adapter represents already verified and already qualified evidence from `AppTransaction`, current entitlements, purchase results, transaction updates and subscription status. It does not reimplement original-purchaser cutover/version/family eligibility. Those remain in the existing [original purchaser policy](../../CodexBarIOS/Services/ProOriginalPurchaserPolicy.swift). Normalized `revision` is a synthetic total order. Actual StoreKit signed dates, purchase-chain identity, replacements and revocation tombstones must map into the native contract rather than trusting callback arrival order. The tests prove this reducer's behavior, not that a merchant supplies such an ordinal.

The prototype retains its in-memory source/revision tombstones to prevent stale replay. It persists nothing automatically and can be discarded by ending the process. Apple-local tests never bind an account. The production Apple cache must continue omitting transaction and Apple Account identifiers, as required by #464; the fixture's chain IDs are for test assertions only and are not a proposed App Group schema. No billing account exists to delete in the selected boundary. Deleting app data removes local cache; native verified restore, not a new charge, is the recovery path.

## Explicitly excluded hypotheticals

`Proposal`, `Ledger.bind/delete/recover/checkout` and `test_hypothetical_shared.py` are isolated research fixtures, excluded from all product promises and Apple-local acceptance. Every policy instance is labeled `UNAPPROVED PROPOSAL`. They model candidate cross-source account binding, stale sessions after deletion, retained binding tombstones, synthetic recovery proof, subscription allowances and finite shared lifetime leases. Only the invented `TEST` region can simulate checkout in these experiments. No real storefront is approved by that value.

These fixtures can compare per-store and shared candidate policies, but neither their passing tests nor prior plan recommendations authorize a shared service. Their account-deletion retention and recovery are hypothetical choices, not an approved privacy contract. They use a trusted fixture oracle and in-memory ledger; they do not prove durable backend transactions, concurrent checkout exclusion, authenticated sessions or secure proof. New implementation must not import them into production.

## Remaining integration gates and decisions

The selected Apple-local product needs no sharing policy decision to use these fixtures. Outstanding native integration gates are verified StoreKit authenticity and app/product/environment identity, finish-after-save ordering, secure cache persistence and revocation replay protection, trusted clock/continuous-time and reboot recovery, real StoreKit pending/cancel/error reconciliation, and StoreKit sandbox restore/refund/family behavior. Those are not replaced by a Python pass.

Native Mac remains provisional. Its owning qualification must prove sandbox/provider authorization, platform-aware original-purchase version interpretation and valid restoration under the chosen app record before promising universal purchase or compatibility. The existing release gate also owns re-verification of the original-purchaser cutover. No signing, store record, submission or release artifact is produced here.

Shared accounts, cross-platform lifetime grants, shared original/family eligibility, service ownership/budget/hosting, authentication/recovery, retention/deletion terms, cross-merchant prices/trials/overlap, seller/tax/refund/dispute responsibility, regions and store programs remain excluded. They require a new explicit decision and secure integration qualification if scope changes later. Production checkout and backend remain absent.
