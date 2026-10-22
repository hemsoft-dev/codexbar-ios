# Build 6 release preparation

> **Superseded October 22, 2026.** Franz kept build 5, which was submitted for
> App Review with the `2026-11-01T00:00:00Z` cutoff. Build 6 was never uploaded.
> See [APP-STORE.md](../APP-STORE.md#build-5-qualification-and-submission) and
> [#515](https://github.com/hemsoft-dev/codexbar-ios/issues/515).

Prepared October 21, 2026 EDT for the planned October 23 submission under
[issue #470](https://github.com/hemsoft-dev/codexbar-ios/issues/470).
This records preparation, not submission or distribution. Franz approved the
submission target and Apple-local Pro scope; store writes and launch actions
still require his separate approval.

## Boundary and copy

The last live source is
[`v1.4.0`, 54b2a48](https://github.com/hemsoft-dev/codexbar-ios/tree/v1.4.0).
The candidate is version 2.0.0, build 6 in all fourteen project configurations.
The [2.0 changelog](../CHANGELOG.md#200---2026-10-22) remains Unreleased
until the release date is established. October 23 records the planned submission
target only. Update its heading and all inbound anchors together when that date
is known. Published 1.x history is unchanged.

The [local What's New](../fastlane/metadata/en-US/release_notes.txt) summarizes
customer changes since 1.4.0. It excludes Developer Experience work, synthetic
Pro research and provisional Mac tooling. No desktop release or shared service
is included. The [scope decision](2026-10-21-pro-scope-decisions.md) remains
Apple-local Pro with provisional native Mac qualification.

| Copy claim | Changelog evidence |
| --- | --- |
| Free plan, saved-account retention and Pro access | [#466](https://github.com/hemsoft-dev/codexbar-ios/issues/466), [#467](https://github.com/hemsoft-dev/codexbar-ios/issues/467) |
| Products, trial, purchase recovery and subscription management | [#468](https://github.com/hemsoft-dev/codexbar-ios/issues/468), [#490](https://github.com/hemsoft-dev/codexbar-ios/issues/490) |
| Original-purchaser lifetime, family deadline and disclosures | [#465](https://github.com/hemsoft-dev/codexbar-ios/issues/465), [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469), [#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) |
| X Subscription pool and credits | [#458](https://github.com/hemsoft-dev/codexbar-ios/issues/458) |
| Provider renewal dates | [#444](https://github.com/hemsoft-dev/codexbar-ios/issues/444), [#446](https://github.com/hemsoft-dev/codexbar-ios/issues/446), [#451](https://github.com/hemsoft-dev/codexbar-ios/issues/451), [#456](https://github.com/hemsoft-dev/codexbar-ios/issues/456) |
| Greptile credits and Claude saved resets | [#429](https://github.com/hemsoft-dev/codexbar-ios/issues/429), [#420](https://github.com/hemsoft-dev/codexbar-ios/issues/420) |
| iPad scrolling and widget readability | [#496](https://github.com/hemsoft-dev/codexbar-ios/issues/496), [#473](https://github.com/hemsoft-dev/codexbar-ios/issues/473) |

The cutoff remains November 5, 2026 at 7 PM EST, November 6 at midnight UTC.
It is fourteen calendar days after the planned October 23 submission. The
compiled policy, localized original-purchaser notice and local release/review
copy agree. Moving the planned date requires a revised cutoff and qualification.

## Immutable candidate handoff

Merge this preparation and the intended qualification work before freezing the
candidate. Record the final merged SHA in the release issue and local mission
ledger. Do not qualify a moving branch, reuse build 5's results, or call this
preparation qualified. A change to the frozen candidate invalidates its gates.

Run all release checks on air with Xcode 26.6 build 17F113, iOS 26.2 build 23C54
and watchOS 26.5 build 23T570. Retain the seven local perfection gates, full
native commerce matrix, disjoint-line coverage proof and iOS/watchOS risk gates,
complete iPhone and iPad UI manifests, pinned CodeQL analysis and performance
budgets. Report local and hosted results separately. Required automatic PR
SwiftLint remains the normal merge gate; no automatic workload is added.

Retain the existing App Store asset index and saved placement audit. Later PR
captures have separate source provenance and do not mean saved App Store images
were replaced. Verify the actual uploaded bytes and metadata before any write.

Build 5 remains the selected unsubmitted draft at the earlier cutoff. Prepare
and verify the replacement archive/export locally, then present its SHA, build,
cutoff, exact copy, gates and pending checks for Franz's final approval. No
upload, build selection, metadata write, first-product submission, release,
price or availability change is authorized by this preparation.

Keep [#469](https://github.com/hemsoft-dev/codexbar-ios/issues/469) and
[#470](https://github.com/hemsoft-dev/codexbar-ios/issues/470) open until their
actual submission and rollout criteria are met. Small Business enrollment,
legal agreements and production original-purchaser/Family Sharing checks remain
pending for Franz. They are not invented passes.
