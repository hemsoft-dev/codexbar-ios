# Claude Usage Data Sources

CodexBar reads Claude subscription usage from:

```text
GET https://api.anthropic.com/api/oauth/usage
anthropic-beta: oauth-2025-04-20
User-Agent: CodexBarIOS
```

This is an undocumented provider endpoint, so every field is decoded
defensively and optional values are omitted when absent or malformed.

## Client identity, sign-in scope and refusals

CodexBar names itself in the user agent of every request it sends to a Claude
host ([#589](https://github.com/hemsoft-dev/codexbar-ios/issues/589)). The
value is `User-Agent: CodexBarIOS`, from one constant, `ClaudeClientIdentity`.
No request's user agent names Claude Code or any other client, and a refused
request is never sent again under a different identity. Sign-in and renewal
still carry Claude Code's public client identifier; see below.

| Request | User agent before | User agent now |
| --- | --- | --- |
| Usage and saved-reset inventory read | `claude-code/2.1.0` | `CodexBarIOS` |
| Token exchange at sign-in, token renewal | Not set by the app; URLSession supplied its default | `CodexBarIOS` |
| Profile read, reset client reads and reset request | `CodexBarIOS` | `CodexBarIOS` |
| Billing lookups (paused in production, shared helper with Grok) | `CodexBarIOS` | `CodexBarIOS`, now from the same constant |
| Claude's sign-in page | Safari's own, not set by the app | Unchanged |

Guided sign-in asks for `user:profile user:inference`. It used to ask for
`org:create_api_key user:profile user:inference user:sessions:claude_code`.

| Scope | The request that needs it | Evidence |
| --- | --- | --- |
| `user:profile` | Usage read, saved-reset inventory, profile read | [Desktop CodexBar](https://github.com/steipete/CodexBar/blob/1f6da9bec44455288ddee5ef6f3617a803d8eb2a/docs/claude.md#L236); [OpenUsage #1448](https://github.com/robinebers/openusage/pull/1448) narrowed its sign-in to this scope alone, and [#1652](https://github.com/robinebers/openusage/pull/1652) reports that sign-in reading usage |
| `user:inference` | Using a saved reset (`reset_rate_limits`) | OpenUsage #1652 reports HTTP 401 on that request with a `user:profile`-only token |

CodexBar sends no inference request, creates no API key and opens no Claude
Code session. `user:inference` is kept only because the reset request is
reported to need it; if a live check shows that saved resets are not offered to
CodexBar at all, it should be dropped. Asking for a scope later would make
people sign in again, while dropping one would not, so the wider of the two
candidate sets is the reversible choice.

What stays the same, and what this does not establish:

- Sign-in still goes through the public Claude Code client identifier, because
  CodexBar has no client registration of its own. Only the user agent is
  truthful. Whether this sign-in is permitted is
  [#548](https://github.com/hemsoft-dev/codexbar-ios/issues/548), and the
  release hold stays.
- `anthropic-beta: oauth-2025-04-20`, `anthropic-version: 2023-06-01` and the
  `cedar_ember=1` query are kept as protocol parameters.
- Accounts signed in earlier are not signed out, migrated or rewritten. Renewal
  sends the same body as before, with no `scope`. Their tokens keep whatever
  Claude granted at the time; CodexBar does not use the extra permissions. What
  Claude does with an earlier grant after a new sign-in is not established.

How Claude responds to this identity is not known. Public reports from March
2026 say the usage endpoint rate-limited user agents other than Claude Code
([desktop CodexBar #487](https://github.com/steipete/CodexBar/issues/487)), and
one report says saved resets are listed only for Claude's own command-line
client, with `ineligible_reason: "surface"` for others, including the
`claude-code/…` user agent this app sent before
([desktop CodexBar #3895](https://github.com/steipete/CodexBar/issues/3895)).
Both are second-hand. OpenUsage's reports were made with a Claude client user
agent, so nothing shows the narrower scopes working together with CodexBar's
own name. If Claude refuses, the card says so and the app does not
change identity:

| Claude's answer | Card message | Offered |
| --- | --- | --- |
| Usage 401 or 403 whose body says "scope requirement" | "Claude says this sign-in does not include permission to read usage. Sign in again to grant it." | Sign in again |
| Usage 401, renewal refused with `invalid_grant` (as the error code, or as an error object's type or code) | "Claude did not renew this sign-in: HTTP 400 (invalid_grant). Sign in again." | Sign in again |
| Usage 401, renewal refused or failed any other way | "Claude could not renew this sign-in right now: HTTP 503. Your sign-in was not changed." | Retry |
| Usage 401 with a token Claude renewed and has refused since | "Claude declined CodexBar's usage request (HTTP 401). Your sign-in was not changed." | Retry |
| Usage 401 otherwise | "Claude credential was rejected. Sign in again." | Sign in again |
| Usage 403 otherwise, and any other unexpected status | "Claude declined CodexBar's usage request (HTTP 403). Your sign-in was not changed." | Retry |
| Usage 429 | "Claude usage is rate-limited until …" (unchanged) | Retry |
| Reset request 401 or 403 | "Claude did not allow CodexBar to use this reset (HTTP 401). No reset was used." | None |
| Inventory not eligible, reason `surface` | "Saved resets unavailable", and in the sheet "Claude did not offer saved resets to CodexBar." | None |

The aim is to offer sign-in only where a new sign-in can help. "Retry" means
no sign-in prompt: the card shows a Retry button, beside the last known usage
when this session has any. Limits of that aim:

- The last known usage is held in memory. A refusal on the first refresh after
  launch, for example right after an update, shows the message with no usage.
- A token Claude renewed and then refuses stays "declined" across refreshes
  only until the app restarts. After a restart, or for a token that was never
  renewed in this session, a plain 401 reads "Claude credential was rejected.
  Sign in again.", because the app cannot tell a refused identity from a
  rejected token.
- A renewal refused in a way that does not name `invalid_grant` offers Retry
  even if the refresh token is in fact dead. Sign in Again in the account's
  settings still works.
- Reading `surface` as "not offered to CodexBar" is an interpretation of one
  public report. The sheet says only that Claude did not offer saved resets.

No state deletes or rewrites the saved sign-in. The
"scope requirement" wording comes from a
[public report](https://github.com/anthropics/claude-code/issues/22450) that
shows the text without its status, so the app accepts it on either status. If
Claude refuses the narrower sign-in on its own page, the app receives nothing.
Closing the sheet from the dashboard shows "Claude sign-in canceled. The
existing credential was not changed." Leaving it open for three minutes, or
closing it in account settings (which does not cancel,
[#591](https://github.com/hemsoft-dev/codexbar-ios/issues/591)), shows the
timeout message, which now mentions that Claude may not have accepted the
request.

Pending for Franz, on a live account, in this order: an account signed in
before the change still renews and reads usage; a fresh sign-in completes and
shows usage and the plan name; what Claude's consent page lists; whether saved
resets are still listed and usable. Agents made no request to any Claude host.

## Display ownership

| CodexBar display | Provider field | Behavior when unavailable |
| --- | --- | --- |
| 5-hour percentage | `limits[kind=session].percent`, then `five_hour.utilization` | Omitted |
| 5-hour reset | `limits[kind=session].resets_at`, then `five_hour.resets_at` | `Starts when a message is sent` only when the provider reports zero percent with no reset |
| Weekly percentage/reset | `limits[kind=weekly_all]`, then `seven_day` or `seven_day_oauth_apps` | Omitted |
| Usage credits enabled | `spend.enabled`, then `extra_usage.is_enabled` | State is not inferred |
| Usage credits spent | `spend.used`, then `extra_usage.used_credits` | Omitted |
| Monthly spend limit | `spend.limit`, then `extra_usage.monthly_limit` | Omitted |
| Current balance | `spend.balance` | Omitted; never derived from the monthly limit |
| Remaining spend headroom | `spend.limit - spend.used`, then the equivalent `extra_usage` values | Labeled as derived and never presented as prepaid balance |
| Auto-reload | `spend.auto_reload` | Omitted if the key is absent |
| Spend reset | Not exposed in verified OAuth response shapes | Omitted |
| Promotional credit balance and expiry | `iguana_necktie.remaining_dollars`, `limit_dollars` and `resets_at` | Omitted when the block is absent, null or malformed |
| Temporary-limit notice | Not exposed as a stable, provider-described OAuth field | Omitted; codenames and plan labels are not interpreted as promotions |

## Promotional credit

When the usage response carries an `iguana_necktie` block, "Account details"
shows one "Promotional credit" row, for example "$75.00 of $100.00 remaining,
expires Nov 5, 2026 at 7:59 AM". No extra request is made. The row is separate
from "Current balance", which stays the prepaid `spend.balance`; promotional
amounts are never added to the balance or the spend metrics.

| Field | Use |
| --- | --- |
| `limit_dollars` | Credit granted. Required and greater than zero. |
| `remaining_dollars` | Credit left. Preferred when reported. |
| `used_dollars` | Used only to derive the remainder when `remaining_dollars` is absent. |
| `resets_at` | Expiry, not a recurring reset. Optional. |
| `locked_reason` | Any non-blank reason shows "Not available to use now" with no amount. |

The amounts are US dollars, not minor units, so they are not divided by 100.
A credit whose expiry has passed at refresh shows "Expired" with its date and
no amount. A row kept from the last successful refresh keeps its stated expiry.
A block that is null, incomplete or malformed (a non-numeric amount, a
remainder above the grant, an unreadable expiry) is omitted as a whole and the
card looks exactly as it does without it. Plan names, codenames and offers
never create a credit. The row belongs to the account's own usage result, so
another account, a later response without the block, sign-out or a replaced
credential never shows an earlier credit.

This is an undocumented response shape taken from public implementations:
[desktop CodexBar](https://github.com/steipete/CodexBar/blob/1f6da9bec44455288ddee5ef6f3617a803d8eb2a/docs/claude.md)
documents the fields under "Cloud-session credits", and
[Pane's live-shape test](https://github.com/ItsJazii/pane/blob/beb4bbfd4e7c776d970a56d254e8cce4d61154d9/src-tauri/src/providers/claude.rs#L1049)
records an untouched $100 credit with an expiry. Anthropic describes
promotional credit and its expiry in its
[promotional credit offer terms](https://www.anthropic.com/legal/promotion-credit-terms).
No public or captured response shows any other promotional field, so reload
offers and other credit types remain omitted. CodexBar's tests use synthetic
data; comparison with a live account that holds promotional credit remains
pending for Franz ([#560](https://github.com/hemsoft-dev/codexbar-ios/issues/560)).

## Window labels and plans

The shared session window is labeled "5-hour"; the all-model weekly allowance
is labeled "Weekly". Unified `5h` and `7d` rate-limit headers use the same
labels. Scoped limits retain their model names, and a shared session alongside
scoped sessions keeps its "Other models" qualifier. Metric keys and legacy
widget tile IDs do not depend on these new display labels.

Anthropic's [Ultra plan documentation](https://support.claude.com/en/articles/17728952-what-is-the-ultra-plan)
and [pricing](https://claude.com/pricing) rename Max 20x to Ultra. Max has 5x Pro
usage. Verified Ultra accounts have no five-hour limit; pending verification can
retain that limit. Weekly all-model and Fable limits remain. CodexBar displays
only returned windows, independent of the plan label. Missing or malformed
session data never establishes verification. The existing reported zero-percent
idle session remains visible, including its "Starts when a message is sent" text.
No verification badge, quota multiplier calculation or new usage field is added.

## Subscription-name source and refresh policy

The card pill now reads `GET https://api.anthropic.com/api/oauth/profile` with
its account-scoped Bearer credential, the `user:profile` authorization
scope and `anthropic-beta: oauth-2025-04-20`. Guided phone sign-in
requests that scope. This read-only lookup sends no inference request and
requires no desktop process, exported credentials or additional setup.

Source research for [#431](https://github.com/hemsoft-dev/codexbar-ios/issues/431):

- [T3 Code at `5fe9d024`](https://github.com/pingdotgg/t3code/blob/5fe9d024d9b1c28ec93d495cf1441c57e47ae7ce/apps/server/src/provider/ClaudeProvider.ts#L415)
  reads the Agent SDK initialization account's `subscriptionType`; its
  [label mapper](https://github.com/pingdotgg/t3code/blob/5fe9d024d9b1c28ec93d495cf1441c57e47ae7ce/apps/server/src/provider/ClaudeProvider.ts#L74)
  distinguishes Pro and Max multipliers. Anthropic Agent SDK `0.3.276` declares
  the field in `AccountInfo`. That desktop SDK transport does not run on iOS.
- [Desktop CodexBar at `b8c6a1eb`](https://github.com/steipete/CodexBar/blob/b8c6a1eb8b0e67754806b9aabe0a0186e201afc9/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift#L149)
  supplies the existing OAuth profile route. Its identity parser alone does
  not establish subscription mappings.
- [A first-hand OpenUsage investigation](https://github.com/robinebers/openusage/issues/394)
  reports `organization.organization_type = claude_max` and
  `organization.rate_limit_tier = default_claude_max_20x` after an upgrade,
  while login-time metadata still says 5x. This is an undocumented response
  contract, not a published Anthropic API guarantee or a live CodexBar account
  verification.

| Explicit profile metadata | Pill |
| --- | --- |
| Organization type `claude_pro` | Pro |
| Organization type `claude_ultra` | Ultra, defensive compatibility only; no captured provider payload |
| Organization type `claude_max` and exact tier `default_claude_max_5x` / `max_5x` | Max |
| Organization type `claude_max` and exact tier `default_claude_max_20x` / `max_20x` | Ultra |
| Organization type `claude_max` without a recognized multiplier | Max |
| Organization type `claude_team` / `claude_enterprise` | Team / Enterprise family only |
| No organization type, exactly one true JSON boolean `account.has_claude_pro` / `account.has_claude_max` | Pro / Max family, with an explicit Max tier when present |
| Unknown, missing or contradictory family metadata | Plan unavailable |

Team and Enterprise profile shapes and seat variants have not been verified
against live accounts; only an explicit supported organization family is
accepted. Seat-specific labels, free-plan detection and future tier identifiers
remain unsupported. Quotas, model availability, prices and custom account names
never determine the plan. Team/Enterprise capacity tiers never rename the
explicit organization family. A supported organization type names the plan by
itself: personal `account.has_claude_*` flags never contradict it, as in Claude
Code 2.1.318 (organization type and tier only) and CodexBar for Windows
([#551](https://github.com/hemsoft-dev/codexbar-ios/issues/551)). Without an
organization type, both present personal-plan flags must be actual JSON
booleans and exactly one must be true. Specific login-time names remain a fallback only
until the profile establishes a plan or explicitly establishes no known plan.

Profile requests run alongside usage reads, with a ten-second timeout, refused
redirects and an ephemeral session with cookie and HTTP-credential storage
disabled. Parent-session headers and response cookies do not cross accounts.
Responses over 64 KiB are not parsed.
Concurrent requests share one lookup; the next usage refresh can request a
profile after five minutes. Numeric and HTTP-date `Retry-After` extend that
interval, bounded between five minutes and 24 hours. There are no immediate
retries. A changed supported plan therefore appears without signing out on a
subsequent eligible refresh.

Each in-memory entry belongs to the app account ID and a hash of the access
token, with a fresh generation on replacement. Rotation starts a fresh profile
lookup. Sign-out clears plan and usage caches; late responses are checked
against the currently saved credential before they can publish. Raw profile
identity fields are not saved or sent to widgets, history, logs or backups.
Only the existing public plan descriptor follows the usage snapshot.

A valid profile with unsupported or conflicting fields clears the old label.
Profile 401/403 also clears it without discarding successful usage. Network,
malformed JSON, 404, 429 and server failures retain only the last verified
label for the same account and token, or the explicit credential fallback when
no profile resolution exists. This retained label may be stale; a later valid
profile replaces it. Profile failure does not become a usage failure or trigger
sign-in by itself. Live plan-name and quota comparisons remain pending for Franz.

## Redacted regression shape

The regression test uses the same provider-owned money representation observed
in redacted 2026 OAuth responses:

```json
{
  "limits": [
    {"kind":"session","percent":0,"resets_at":null,"is_active":false},
    {"kind":"weekly_all","group":"weekly","percent":13,"resets_at":"2026-07-27T09:59:00Z","is_active":true}
  ],
  "spend": {
    "used": {"amount_minor":0,"currency":"USD","exponent":2},
    "limit": {"amount_minor":4000,"currency":"USD","exponent":2},
    "percent": 0,
    "enabled": true,
    "balance": {"amount_minor":10000,"currency":"USD","exponent":2},
    "auto_reload": null
  }
}
```

The dollar amounts mirror the issue's redacted first-party comparison target;
the fixture contains no session token, account identifier, cookie, request ID,
or organization ID. A release comparison must refresh CodexBar and Claude
Settings > Usage for the same authenticated account at the same time.

## Saved usage resets

Claude occasionally offers eligible subscriptions a limited number of saved
usage resets. Availability, affected windows and expiration are provider-owned;
a plan label is not evidence of a grant. See Anthropic's
[limit-reset explanation](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset).
A reset restores the allowance immediately without changing the normal weekly
schedule. Its use cannot be undone.

CodexBar reads the optional `cedar_ember` inventory by adding `cedar_ember=1`
to the usage request. Missing, malformed or unsupported inventory is unknown,
not a claimed zero balance. A confirmed empty eligible inventory is zero.
Counts exclude paused, expired and not-yet-started grants. Redemption is offered
for each grant Claude marks `usable_now`, when eligibility holds and any cooldown
has ended. Each such grant is its own choice with its own confirmation, so a
Fable reset and a weekly reset are never used in place of one another. Other
saved grants remain visible with their availability and provider-reported
expiration.

The reset sheet names the account, affected windows, expiration and irreversible
cost of one reset before confirmation. Its count and availability update while
the sheet stays open, and an expired confirmation closes without a request.
Cancelling confirmation sends no reset request. The original confirmed grant
is passed unchanged through the request flow. A refreshed cache cannot replace
its count, affected windows, expiration or other terms. Before a confirmed
request, the client rereads inventory, verifies the OAuth account and
organization, and checks that the confirmation still belongs to the exact
saved credential and grant. A changed account, grant or rotated credential
requires a fresh usage read and a new confirmation.

The organization-bound `reset_rate_limits` POST uses `program=cedar_ember`, the
confirmed grant's own `grant_id` and a new `request_id`. This contract follows the
[current provider implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/claude-reset.ts),
not a stable published Anthropic API. The request identifies CodexBar honestly,
as every Claude request now does; it does not impersonate another client to
obtain reset eligibility. An unsupported
or ineligible provider response leaves redemption unavailable.

No mutation is retried automatically. Redirects are refused before a request can
be replayed or its grant data sent elsewhere. A changed fresh grant requires
new confirmation. Before the POST, an atomic app-private
receipt records only hashes of the provider account/organization and grant,
the remaining count and expiration. It is excluded from backup. Raw grant IDs,
credentials and inventory are not sent to widgets, Apple Watch, usage history,
configuration backups or diagnostics. A timeout, server failure or malformed
success retains the receipt across app restarts and token rotation. Another
POST is blocked until the same grant's fresh count changes or that grant
expires. An absent grant or unreadable receipt does not silently clear the
uncertainty. Every outcome refreshes authoritative usage and inventory;
only a confirmed provider outcome is presented as successful.

This supports saved Cedar grants; the separate Juniper session-reset experiment
is not interpreted as a saved grant. Automated validation uses synthetic data
and blocked networking. Live account eligibility and before/after comparisons
remain pending for Franz.

A visible dashboard reset section updates every second from the provider-returned
grant start and expiry dates, without a usage refresh. The inventory sheet shows Claude's cooldown
end time before generic eligibility messages and removes it once that time passes.
Neither update consumes a reset or changes provider quotas.

### Reset types and choosing a reset

The sheet describes each grant from the windows Claude lists in `clears`:

| `clears` identifier | Sheet wording |
| --- | --- |
| `five_hour` | five-hour usage |
| `seven_day` | weekly usage |
| `seven_day_opus` | Opus weekly usage |
| `seven_day_sonnet` | Sonnet weekly usage |
| `seven_day_overage_included` | Fable weekly usage |
| Any other identifier | provider-scoped usage |

`seven_day_overage_included` is the Fable identifier in two independent public
implementations. [oh-my-pi `d502479`](https://github.com/can1357/oh-my-pi/commit/d502479ba7a152b0cab72d9186d3229b6852cae6)
maps it to the Fable weekly limit. [OpenUsage #1642](https://github.com/robinebers/openusage/pull/1642)
lists it as a Fable reset and reports checking its wording against sanitized
live reset-grant responses from three accounts on November 10, 2026. Anthropic's
[limit-reset explanation](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)
says a Fable reset restores the weekly usage spent on Fable. When Claude also
lists `five_hour` on the grant, the sheet names both. An identifier CodexBar
does not know keeps the general wording and never names an effect Claude did
not report. The `type` and `gives_back_weekly` grant fields that OpenUsage reads
are not used.

OpenUsage #1642 also reports that Claude Code sends the chosen grant's own
`grant_id`, and that Claude can answer `{"result":"unavailable","reason":"not_next_grant"}`
when it wants another reset used first. That answer has not been observed on a
live account: OpenUsage says so, and CodexBar has not used a reset other than
`next_grant_id` on a live account either. CodexBar treats `not_next_grant` as a
confirmed refusal: it reports that Claude declined the reset, removes the
pending receipt and refreshes usage and inventory. Any other `unavailable`
answer stays unconfirmed and keeps the receipt. Live use of a Fable reset beside
a weekly reset remains pending for Franz
([#559](https://github.com/hemsoft-dev/codexbar-ios/issues/559)).
Authentication and client-identity qualification remains separate under
[#548](https://github.com/hemsoft-dev/codexbar-ios/issues/548).

## Fable weekly allowance

When Claude returns a model-scoped weekly allowance in `limits[]`, CodexBar
shows its reported percentage and reset separately from the shared 5-hour and
all-model weekly windows. Enforceable inactive weekly entries remain visible.
Usage credits stay in the money metrics and do not establish a Fable quota.
Missing or malformed percentages are omitted; a genuine reported zero is zero.

[Anthropic's Fable plan documentation](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan)
describes one included cap shared by Fable 5 and 5.1 on eligible plans. It draws
from the shared weekly allowance. The returned model display names `Fable`,
`Fable 5`, `Fable 5.1` and their `Claude`-prefixed forms therefore share the stable
metric ID `claude.weekly-scoped-fable`. Other and future model names retain
their separate identity. Plan labels alone never create an allowance.

Earlier work in [#43](https://github.com/hemsoft-dev/codexbar-ios/issues/43)
already supported generic scoped weekly entries, including plain Fable. The
remaining gap was that documented model-name variants created different metric
IDs, losing saved choices or duplicating one cap in mixed responses. This change
normalizes those known names without assuming a new `seven_day_fable` root field.
The existing provider cache remains account- and credential-bound; local fixtures
verify that a changed credential cannot reuse a previous account's Fable usage.

Synthetic fixtures cover present and absent allowances, usage credits, inactive
entries, model aliases, mixed windows, two accounts, saved visibility and layout,
history, widgets and Apple Watch. Live provider comparison remains pending for
Franz and is not an agent delivery prerequisite.

Saved Fable widget selections match the allowance by identity, never by a former
bar position. If that allowance is absent, the tile stays unavailable instead of
showing the session or all-model weekly quota. Future model names can still match
their own provider-returned identity without becoming aliases of the known cap.

## Ultra compatibility evidence and validation

The legacy `default_claude_max_20x` and `max_20x` values now display Ultra;
`default_claude_max_5x` and `max_5x` display Max. Legacy descriptor IDs stay stable.
Login metadata accepts explicit `ultra` in the existing subscription-type input.
Profile parsing accepts `claude_ultra` in the existing organization-type field as
defensive compatibility. These current-name values are synthetic test inputs,
not verified provider contracts. No `has_claude_ultra`, verification field or new
endpoint is assumed. Unknown family and contradictory known tier metadata do not
produce a plan. Existing credential-bound caching and error handling remain.

Ultra fixtures reuse existing window fields and the legacy Max 20x profile.
The absent-session scenario resembles documented verified behavior and the
present-session scenario resembles pending verification. Neither establishes an
account's actual verification status. No first-party Ultra account payload has
been captured for this change. The original announcement media was unavailable.

On an authorized Mac, run focused native tests with the repository's Xcode
prefix, a suitable installed iPhone simulator and `-only-testing` selections for
`CodexBarIOSTests/ProviderParsingTests`, `CodexBarIOSTests/ProviderNetworkTests`,
`CodexBarIOSTests/ClaudePlanProfileTests` and
`CodexBarIOSTests/ClaudeFableWeeklyTests`. The last suite covers saved metrics,
widgets and weekly consumers. Then run
`CodexBarIOSUITests/CodexCreditsPoolUITests/testClaudeUltraReportedWindowsEvidence`
on iPhone and iPad for synthetic pending-like and absent-session card captures.
Exercise widget previews for both states and attach current-head evidence to the
PR. Native execution and rendered evidence remain required before merge; Linux
source checks cannot substitute for them. Do not dispatch the full release UI
workflow for this routine change.

The local SwiftPM card-label regression can also be run with
`swift test --filter ProviderCardPlanTests`. Profile capacity-tier validation applies
to Max and Ultra; absent or malformed capacity tiers do not hide a known Pro,
Team, or Enterprise family.

## Per-product usage

CodexBar shows no breakdown of Claude usage by product or surface (Claude Code,
chat, artifacts), because no response this app can read is known to report one
([#558](https://github.com/hemsoft-dev/codexbar-ios/issues/558)). This is a
statement of data absence as of November 20, 2026, not a decision against the
feature.

What was checked:

- The usage response fields read by three public implementations at their
  current commits:
  [oh-my-pi `fbb8085`](https://github.com/can1357/oh-my-pi/blob/fbb8085ff432419132c6e3132f36ad857893b1a4/packages/ai/src/usage/claude.ts),
  [OpenUsage `53f70b3`](https://github.com/robinebers/openusage/blob/53f70b396698656cb5e1e3f59c40d1b86d6b5296/Sources/OpenUsage/Providers/Claude/ClaudeUsageMapper.swift)
  and [desktop CodexBar `1f6da9b`](https://github.com/steipete/CodexBar/blob/1f6da9bec44455288ddee5ef6f3617a803d8eb2a/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift).
  All read session, weekly and model-scoped windows, spend and saved resets.
  None reads a share of usage per product.
- Desktop CodexBar also accepts `seven_day_routines` and `seven_day_cowork` as a
  "Daily Routines" window. Its
  [own report](https://github.com/steipete/CodexBar/pull/2450) says a live
  account returned `seven_day_cowork: null`, that a populated value could not be
  produced, and that claude.ai draws its bars from `limits`, which has no
  routines entry. A window nobody has seen populated is not a verified shape, so
  CodexBar for iOS does not read these keys.
- Anthropic documents per-product figures only in the
  [Claude Enterprise Analytics API](https://platform.claude.com/docs/en/manage-claude/analytics-api),
  which needs an analytics key created by an Enterprise organization's primary
  owner. Individual subscriptions cannot use it, and asking for such a key would
  break this app's guided-setup rule.

Until a sanitized response shows product identifiers and units, keys that look
like a product breakdown add no row, no zero value and no error.
`ClaudeWindowLabelTests.testProductKeysWithoutAnEstablishedShapeChangeNothing`
pins that. A model name, a plan label or an active session never implies a
product share. No request is added for this.
