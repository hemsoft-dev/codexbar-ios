# Muse Code allowance contract

Research for [issue #522](https://github.com/hemsoft-dev/codexbar-ios/issues/522),
checked October 26, 2026 EDT. No account, credential, CLI run or private
endpoint was used for this document.

## Result: no supported iPhone source

CodexBar can't show a Muse Code subscription allowance on iPhone. Add Account
explains that limit, and Muse Code can't be added, refreshed or published to the
widget or watch.

| Question | Finding | Source |
| --- | --- | --- |
| Can a third-party app use the subscription credential? | No. "This credential is for use with Muse Code only." Subscriptions "work only through the Muse Code CLI while signed in with your Meta Model API account." Other API keys are pay-as-you-go. | [Subscriptions](https://dev.meta.ai/docs/muse-code/subscriptions) |
| Is there an OAuth, device-code or client-registration flow for apps? | Not documented. Muse Code itself signs in through the browser into the CLI, a pasted key, `META_API_KEY` or `muse auth set`. Precedence: environment key, stored key, then browser session. | [Authentication](https://dev.meta.ai/docs/muse-code/auth) |
| Is there a network usage or allowance endpoint? | No. The API reference covers Responses, Chat completions, Messages, Files, Images, Voice and Models. The web Usage dashboard shows pay-as-you-go token use. | [API reference](https://dev.meta.ai/docs/api-reference), [Billing](https://dev.meta.ai/docs/muse-code/auth#billing) |
| What reads the allowance? | The CLI and its local host only: `muse usage` and `muse exec --json` `run.usage` (1.4.11, 1.4.13), and the session protocol's `usage/read` and `usage/changed` on `muse serve` (1.4.0), which a local app reaches by spawning `muse`. | [Changelog](https://dev.meta.ai/docs/muse-code/changelog) |

The Grok precedent ([GROK-CONSUMER-CONTRACT.md](GROK-CONSUMER-CONTRACT.md))
doesn't carry over. xAI publishes OIDC discovery with a device-code grant and a
public CLI client, and its billing read is a bearer-token HTTP call. Meta
documents neither, and restricts the subscription credential to Muse Code.
Reusing the CLI's private sign-in, scraping the web dashboard or relaying a
desktop reading would need undocumented endpoints or credential transfer, which
[AGENTS.md](AGENTS.md#end-user-experience-and-live-verification) rules out.

Live support needs both of these from Meta:

1. An authorization a third-party iOS app can complete on the phone, with a
   registrable client, whose grant covers reading the subscription allowance.
2. A documented network endpoint that returns the allowance for that grant.

## Schema 1 reader

`MuseCodeAllowance` parses schema 1 of `muse usage --json`, pinned to Muse Code
`1.4.13-R6996.1`. It follows the shipped producer contract in
[hs-pi-dashboard](https://github.com/hemsoft-dev/hs-pi-dashboard/blob/588be884153122145435e5b05190815bfa54d378/internal/usage/testdata/muse/README.md)
and [CodexBar for Windows](https://github.com/hemsoft-dev/codexbar/pull/274).
Nothing in the app calls it yet; it exists so a future supported source maps
through tested states.

| Payload field | App result | Rule |
| --- | --- | --- |
| `schemaVersion` | — | Must be the number 1. Missing, a string or any other value is "unsupported format". |
| `allowance: null` | Unavailable, no bars | Distinct from a numeric 0. Pay-as-you-go and a missing subscription look the same here. |
| `allowance.asOfMs` | "Measured" detail, and `barsFetchedAt` when stale | Missing is "measurement time missing". More than 60 seconds in the future is unavailable. |
| `allowance.window` | `museCode.window`, "5-hour" bar | Reset must be after `asOfMs`, after now, and at most 5 hours after `asOfMs`. |
| `allowance.weekly` | `museCode.weekly`, "Weekly" bar | Reset must be after `asOfMs`, after now, and at most 7 days after `asOfMs`. |
| `usedPercent` | `used` of 100 | A 0–100 percentage used. Above 100 caps the bar at 100; the forecast keeps the raw value. Negative, strings and booleans drop the window. |
| `resetsAtMs` | `resetsAt` | Milliseconds since 1970. Strings are rejected. |
| `tier` | Plan pill | Kept only if it matches `^[A-Za-z0-9 ._()+-]{1,64}$`. Wonder Full is never inferred. |
| `source` | "Source" detail | Kept only if it matches `^[a-z0-9_-]{1,32}$`. |
| other window-shaped keys | Usage message only | Named if they match `^[A-Za-z0-9_-]{1,40}$`, otherwise counted. Never a bar. |
| token totals, `billing`, models | Ignored | Never quota. |
| `reason`, `hint` | Never read | Free-form text that can carry identity. |

Each window is validated on its own. An invalid window gets an "Unavailable"
metric and a usage message while its sibling stays. With no valid window the
result is unavailable. A window whose reset has passed since the measurement is
dropped (reset rollover).

### Freshness

A reading measured more than 7 minutes before the refresh (the producer's
`freshForSeconds: 420`) keeps its bars with `barsFetchedAt` set to the
measurement time. Dashboard, widget and watch then show it as last known; it
raises no new alerts, adds no history and has no forecast. A failed read keeps
the last good bars with their original time.

### Unavailable states

Each state has its own message and none shows zero, unlimited or healthy
quota.

| State | Message | Origin |
| --- | --- | --- |
| Not on iPhone | Muse Code isn't available on iPhone… | This document |
| Allowance not reported | `allowance: null` | Parsed |
| Unsupported format | `schemaVersion` | Parsed |
| Unreadable | Truncated or wrongly typed JSON | Parsed |
| Measurement time missing / in the future | `asOfMs` | Parsed |
| No valid windows | Every window invalid, or tokens only | Parsed |
| Sign-in expired (asks to sign in again) | — | Constructed |
| No subscription allowance | — | Constructed |
| Pay-as-you-go billing | — | Constructed |
| Rate limited, timed out, unreachable | — | Constructed |

"Constructed" states have no known wire shape. The producer reports them as
`allowance: null` with free-form `reason` text, which the app never reads.
They are tested as states, not as parsed fixtures, until a supported source
defines them.

### Not reported by schema 1

Billing mode, pool or model scope, absolute units or caps, and per-model
windows. The app shows none of them and derives none from plan multipliers,
token totals or the published prompt range. Monthly renewal isn't a quota
reset. OpenCode's Muse Spark and pay-as-you-go Meta API keys are separate pools.

### Alerts and surfaces

- Alerts use only current bars, so stale or unavailable readings raise none.
- Widget and watch snapshots carry bars, plan label and times only. No
  credential or new networking reaches an extension.
- Muse Code isn't a widget focus choice.

## Fixtures and tests

`CodexBarIOSTests/MuseCodeAllowanceTests.swift` holds the fixtures. `measured`
is the producer's real reading without identity; everything else is synthetic:
zero, exhausted, partial, malformed values, reset beyond the window, reset
rollover, unsupported schema, truncated, null allowance with synthetic
identity-bearing `reason`/`hint`, pay-as-you-go, undocumented window with token
totals, tokens only, stale and future observations. Tests also cover:

- distinct unavailable states;
- no score;
- metric choices;
- the widget, watch and history round trip;
- account creation on free and Pro plans;
- refresh exclusion;
- unchanged identifiers for existing providers.

The DEBUG simulator scenario `muse-code-states` (`UITestMuseCodeFixture`)
renders synthetic cards through the real dashboard for UI evidence. The shipping
app can't reach those cards.

## Requirements for a future source

- Bind each reading to the verified account and drop late responses after an
  account switch (the refresh service's generation check).
- Reject a measurement older than the cached one before replacing it.
- Pin a `reason` vocabulary, or an equivalent status, before telling expired
  sign-in, entitlement, pay-as-you-go and rate limits apart.
- Save credentials only in Keychain, and only after a verified sign-in.

Franz's real-account phone comparison stays pending until such a source exists.
