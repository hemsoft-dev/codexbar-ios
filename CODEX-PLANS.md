# Codex subscription names

The Codex card identifies the ChatGPT subscription independently of the account
nickname. Plan names come from the authenticated usage response's `plan_type`,
not from token claims, allowance sizes, spend or a user-entered plan choice.
The existing guided phone sign-in is sufficient; no additional lookup is made.

## Verified mappings

Verified on October 10, 2026 against OpenAI Codex revision
[`806d973`](https://github.com/openai/codex/tree/806d9732c974bc8a51b8317c1bd8985544fe627c).
The [account plan enum](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/protocol/src/account.rs)
serializes `Pro`, `ProLite` and `ProMax` as `pro`, `prolite` and `promax`.
The [TUI subscription formatter](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/tui/src/subscription.rs#L9)
explicitly maps those variants to Pro 200, Pro 100 and Pro 500.
The [status formatter tests](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/tui/src/status/helpers.rs#L185)
assert all three numeric names. The [usage response schema](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs)
uses the same identifiers.

| Authenticated `plan_type` | Card pill |
| --- | --- |
| `prolite` | ChatGPT Pro 100 |
| `pro` | ChatGPT Pro 200 |
| `promax` | ChatGPT Pro 500 |
| `plus` | ChatGPT 20 |
| `free`, `go` | ChatGPT Free or Go |
| `business`, legacy `team` | ChatGPT Business |
| `enterprise`, `edu`, `health`, `gov` | ChatGPT Enterprise, Edu, Health or Gov |
| Missing, malformed or unrecognized | Plan unavailable |

Existing normalized identifiers remain stable, such as `codex.pro`,
`codex.prolite` and `codex.plus`. Display and accessibility text match, and the
existing card layout can wrap longer names while preserving independent controls.
There is no family-only Pro response field in the inspected usage schema:
`pro` specifically identifies Pro 200. Unknown values stay unavailable rather
than being guessed as Pro or a numeric tier.

## Subscription names and display preferences

[OpenAI's consumer documentation](https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers)
names the billing plans Pro 100, Pro 200 and Pro 500. The numeric mapping above
comes directly from OpenAI's formatter, not allowance amounts or an inferred
monthly charge. These labels identify the subscription; they do not promise a
permanent multiplier, grandfathered allowance or a localized invoice amount.

[OpenAI calls the $20 plan ChatGPT Plus](https://help.openai.com/en/articles/6950777-what-is-chatgpt-plus).
The pill uses **ChatGPT 20** at Franz's explicit request in
[#435](https://github.com/hemsoft-dev/codexbar-ios/issues/435). This is a display
preference, not an official rename or a measurement of the account's payment.

The earlier research inspected the
[generic authentication formatter](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/protocol/src/auth.rs),
which uses Pro, Pro (More) and Pro (Max), and missed the separate numeric
subscription formatter. That limitation is now resolved by the first-party
source above. No additional network lookup, credential export or manual tier
selector is needed.

[T3 Code's resolver](https://github.com/pingdotgg/t3code/blob/dd4549eede928f9dc514778aeae15d74656a87f8/apps/server/src/provider/CodexProvider.ts#L115)
uses the same identifiers with historical 5x/20x labels and Pro Max.
[Desktop CodexBar's formatter](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift)
also uses historical multipliers. Neither is the source for our numeric names,
and no multiplier is added to the iOS pill.

## Refresh and isolation

Each usage response supplies the current plan. A successful response with an
unknown or malformed plan clears an earlier plan without discarding valid usage.
An optional reset-inventory request failing does not discard the usage or plan.

Publication checks the currently saved access token and account identity before
the request, after its response and after reset enrichment. A replaced or deleted
credential cancels the old result. Cached results are bound to a SHA-256 digest
of the credential's access token and authenticated account ID. Transient failures
can reuse that matching snapshot; authentication failures and missing or replaced
credentials cannot reuse it. The digest is internal cache metadata, not a plan
source. It contains no readable credential and is not exposed in the card.

## Validation

The local-only Codex SwiftPM tests cover mappings, unknown/malformed values,
refresh transitions, optional inventory failure, credential replacement, sign-out,
late responses and account isolation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter CodexUsageTests
```

The existing native pill journey uses isolated synthetic accounts and the
production Codex provider/parser with intercepted HTTP. It covers all three Pro
identifiers, Plus, unavailable data, custom titles, collapsed refresh upgrades,
light/dark appearance and default/accessibility text sizes on iPhone and iPad:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexBarIOS.xcodeproj -scheme CodexBarIOSUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testPreciseSubscriptionPillsOnExpandedAndCollapsedCards test
```

These checks remain local or manual. Full release validation is unchanged.
Live account-to-provider subscription comparison belongs to Franz and remains
pending until he reports a result. Synthetic fixtures do not claim live access.
