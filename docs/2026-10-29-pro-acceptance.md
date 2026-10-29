# Pro setup acceptance checkpoint

For [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469), checked October
29, 2026. No App Store Connect changes, purchases or submissions were made.
This distinguishes completed setup from the remaining release and owner steps.

| Acceptance item | State and evidence |
| --- | --- |
| CodexBar Pro subscription group; yearly level 1 at $14.99 with seven-day trial; monthly level 1 at $1.99 | Done. October 29 GETs of subscriptions `6824195239` and `6824195141`, their USA prices and introductory offers confirm these settings. Both products are APPROVED. Group `22490183` was recorded in the [October 18 configuration receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6249425936). |
| Non-consumable lifetime at $29.99, submitted with 2.0 | Done. October 29 GET of `6824195355` confirms NON_CONSUMABLE and APPROVED. $29.99 and submission with all products/group are recorded in the [October 22 readback](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6340791288); lifetime price was not freshly re-read in this checkpoint. |
| US base; Family Sharing off; grace 16 days; multiseat default | Done per October 18/22 receipts above. Fresh October 29 reads confirm Family Sharing false for all products, both subscriptions at multiSeatStatus ENABLED, and grace optIn/sandboxOptIn true, SIXTEEN_DAYS, ALL_RENEWALS. USA subscription prices were re-read; base settings remain dated evidence. |
| en-US metadata, review screenshot per product, sandbox exclusion notes | Done per October 22 receipt. October 29 subscription localizations are en-US APPROVED; both screenshot deliveries COMPLETE; all three product review notes explicitly exclude sandbox and TestFlight original purchases. Lifetime screenshot/localization retain dated evidence. |
| APP-STORE.md Free/Pro pricing and launch sequence | Repo disclosure done in [#486](https://github.com/hemsoft-dev/codexbar-ios/pull/486). Download transition remains a Franz step under [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470). Historical $3.99 references intentionally document the paid phase; deleting them would corrupt the ledger. |
| PRIVACY.md Purchases section | Done in [policy](../PRIVACY.md#purchases); this PR makes Apple payment handling explicit. |
| SUPPORT.md Restore, original purchaser, family cutoff, offer-code route | Done in [support](../SUPPORT.md#codexbar-pro-and-restoring-purchases), with final October 31, 8 PM EDT cutoff. |
| Description links to standard EULA and privacy; promotional text | Done. [Description](../fastlane/metadata/en-US/description.txt) and [promotion](../fastlane/metadata/en-US/promotional_text.txt); submitted copy confirmed October 22. No live metadata was overwritten with current 2.0.1 preparation. |
| Product page labels widgets, multiple accounts and long history Pro | Submitted assets done per October 18/22 receipts. [Caption manifest](../release-assets/2.0.0/captions.json) labels these CodexBar Pro. The [October 21 image evidence](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6331740815) is source 30f8f208/build 6, not shipping build 5 or current main. Literal current-head screenshot validation remains incomplete; this documentation-only PR does not regenerate native screenshots. |
| Privacy label Data Not Collected | Confirmed in October 18 receipt. No data collection was added here. Current ASC privacy-label readback is not claimed. |
| Changelog matches shipped 2.0 | Checked [2.0.0 section](../CHANGELOG.md#200---2026-10-22) against build-5 release record. It records submission October 22; public release observed October 23. 2.0.1 remains Unreleased, including #529. Do not relabel the historical submission date as an observed release time. |
| Build number at least 5 | Done. October 29 version/build GET confirms selected VALID build 5, ID e224b2b9-c59a-44ff-bd92-d1ed7a0f6b02. Main carries later build preparation. |
| Small Business Program before shipping | Missed/unverified. [October 21 receipt](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6326082769) inferred non-enrollment from proceeds. The [October 22 update](https://github.com/hemsoft-dev/codexbar-ios/issues/469#issuecomment-6340791288) marks enrollment optional. Neither proves current enrollment or waives it on Franz's behalf. 2.0 has already shipped; enrollment now cannot satisfy the original timing criterion retroactively. |

## Remaining owner steps

Franz should confirm eligibility and enrollment in the
[Small Business Program](https://developer.apple.com/app-store/small-business-program/)
as Account Holder, or explicitly accept leaving it unenrolled. Record the
outcome instead of treating the sales-report inference as an enrollment check.

In [App Store Connect](https://appstoreconnect.apple.com/apps/6787769891), verify
current privacy remains Data Not Collected and that the live page retains the
approved Pro captions and EULA/privacy links. No new Pro products or submission
are needed. Complete Free pricing under
[#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470). Family Sharing
and post-cutoff production checks remain Franz-owned release validation.

For literal current-head screenshot acceptance, engineering must capture the
next shipping candidate on macOS using the existing asset workflow. Historical
build-6 images must not be presented as current main or build-5 evidence. No
paid CI or full UI workflow was dispatched by this documentation task.

#469 remains open for explicit enrollment disposition, fresh privacy/product-page
confirmation, and the screenshot evidence qualification above. Its ASC product
setup is complete; it is not active implementation waiting for an agent.
