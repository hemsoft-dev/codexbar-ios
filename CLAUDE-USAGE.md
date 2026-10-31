# Claude Usage Data Sources

CodexBar reads Claude subscription usage from:

```text
GET https://api.anthropic.com/api/oauth/usage
anthropic-beta: oauth-2025-04-20
```

This is an undocumented provider endpoint, so every field is decoded
defensively and optional values are omitted when absent or malformed.

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
| Promotional amount/expiry | Not exposed as a stable, provider-described OAuth field | Omitted |
| Temporary-limit notice | Not exposed as a stable, provider-described OAuth field | Omitted; codenames and plan labels are not interpreted as promotions |

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
its account-scoped Bearer credential, the existing `user:profile` authorization
scope and `anthropic-beta: oauth-2025-04-20`. Guided phone sign-in already
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
explicit organization family. Both present personal-plan flags must be actual
JSON booleans before they can establish or contradict a family. Specific login-time names remain a fallback only
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
only for the provider-selected `next_grant_id` when it is marked `usable_now`,
eligibility holds and any cooldown has ended. Other saved grants remain visible
with their availability and provider-reported expiration.

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
selected `grant_id` and a new `request_id`. This contract follows the
[current provider implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/claude-reset.ts),
not a stable published Anthropic API. The request identifies CodexBar honestly;
it does not impersonate another client to obtain reset eligibility. An unsupported
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
