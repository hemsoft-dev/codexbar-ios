# Pro scope decisions — October 21, 2026

Franz recorded these decisions in the current merge-mission conversation for
[the scope gate](https://github.com/hemsoft-dev/codexbar-ios/issues/475) and
[desktop qualification](https://github.com/hemsoft-dev/codexbar-ios/issues/476).

| Decision | Recorded direction | Consequence |
| --- | --- | --- |
| Purchase scope | Keep Apple-local Pro | Preserve the existing account-free iOS/watchOS contract. No shared billing account or cross-merchant entitlement service is approved. |
| Desktop | Qualify native Mac provisionally | Local sandboxed prototype and test purchases may proceed. A paid desktop launch, platform addition to the production app record and original-buyer portability are not approved. |
| iOS submission target | October 23, 2026 (superseded) | Superseded October 22: Franz kept build 5, submitted October 22 with cutoff October 31 at 8 PM EDT (November 1 at midnight UTC). Build 6 was never uploaded ([#515](https://github.com/hemsoft-dev/codexbar-ios/issues/515)). |
| External actions | Ask Franz before final action | App Store submission/release, pricing/availability changes, customer publication and spending remain approval-gated. |

These directions narrow the [synthetic prototype](https://github.com/hemsoft-dev/codexbar-ios/issues/477)
to the Apple-local contract. Shared accounts, cross-merchant charging, shared
lifetime leases and deletion/recovery of a billing account are outside the
approved implementation. They must not appear as delivered product features.
Synthetic Apple receipts prove state handling only; they do not authenticate a
merchant, establish universal-purchase eligibility or qualify production restore.

## Preserved Apple behavior

The [approved Apple plan](2026-10-16-codexbar-pro-plan.md) retains its monthly,
yearly/trial and lifetime products, original-purchaser recognition and offline
rules. This decision adds no account requirement, new charge, new price or
cross-platform lifetime promise. Refund of one source must not remove a different
valid lifetime grant. A Mac prototype must distinguish macOS marketing-version
receipt semantics from iOS build numbers and must not reuse the iOS original
purchase rule as evidence of Mac eligibility.

## Remaining Franz decisions

The scope gate remains open. A provisional qualification is not the selection of
a first paid channel or its launch regions. No new desktop prices/trials,
original-iOS/family portability, cross-merchant duplicate-payment or lifetime
transition policy has been approved. Shared-service account/recovery method,
owner, budget, hosting region, retention/deletion policy, privacy changes,
merchant of record, tax/refund/dispute owners and regional enrollment are
unselected and inapplicable to the current Apple-local preparation. If shared
Pro is reconsidered, record every decision before enabling checkout.

The [October 17 platform research](2026-10-17-codexbar-pro-platform-plan.md)
remains dated research, not new authority or a current merchant qualification.
No commerce enrollment, contract acceptance, store record, backend, customer
publication or spending is performed by this decision record.
