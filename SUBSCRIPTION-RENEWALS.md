# Subscription billing dates

Issue [#444](https://github.com/hemsoft-dev/codexbar-ios/issues/444) adds a compact
billing countdown and a default-on Dashboard preference. A quota reset, free
allowance refresh or projected billing-period boundary is not proof of a future
charge. The app never estimates renewal dates from plan names, prices or quotas.

## Current connection coverage

Source inspection on October 10, 2026 found these boundaries. Availability is
specific to the product and authentication method already connected in this app.

| Provider | Current evidence | Billing renewal support |
| --- | --- | --- |
| ChatGPT / Codex | `GET chatgpt.com/backend-api/subscriptions`, `active_until` plus Boolean `will_renew` | For verified individual Go, Plus and Pro plans, an optional request uses the existing account-bound OAuth grant, account query/header and Codex client identity headers. Business, Enterprise and unknown workspace plans lack a verified workspace billing contract and receive no lookup. A recognized 200 response supplies the date; rejected access or missing fields means unavailable. The inspected Codex Switch implementation reports successful OAuth reads with this request contract; native iOS transport/grant compatibility remains pending Franz's account check. |
| Claude | OAuth profile identity plus an optional, separate Claude web session | Implemented for personal Pro/Max: **Connect Billing** in account settings opens a private phone sign-in, verifies the web account UUID and organization against the current OAuth profile, then reads `GET /api/organizations/<uuid>/subscription_details`. `status` is required; timestamp and legacy date aliases are optional alternatives, with at least one recognized date key. Malformed present fields and paused payments are rejected. An access-end date overrides a residual next charge. Store/marketplace-managed organization types are excluded; null Stripe status is unsupported. There is no cross-app StoreKit lookup. Live account compatibility is pending Franz. |
| Cursor | `GetCurrentPeriodUsage` exposes a usage period; `/auth/full_stripe_profile` supplies membership | The official client exposes `pendingCancellationDate`, but no verified next-charge timestamp plus affirmative renewal and billing-owner contract. `billingCycleEnd` remains a quota-period boundary, never a promised charge. |
| Copilot | Copilot quota windows | No per-subscription billing renewal and auto-renewal state in the connected quota response. |
| GitHub billing | Account or organization metered usage | Product usage and invoice periods do not identify an individual renewing subscription. No renewal pill. |
| Grok | Optional private Grok web session, `GET grok.com/rest/subscriptions` | Implemented for one active personal SuperGrok subscription with an exact `xaiUserId` match to the connected OAuth subject. Stripe uses `currentPeriodEnd` and Boolean `cancelAtPeriodEnd`; Google purchases use `expiryTime` and `autoRenewEnabled`; Apple purchases require provider-reported `billingPeriodEnd` and `autoRenewOn`. Missing or contradictory state, multiple active personal subscriptions, payment grace/hold, X, enterprise, API and complimentary grants are excluded. Weekly quota dates remain usage resets. Live account compatibility is pending Franz. |
| Google Gemini | Code Assist tier metadata and Gemini usage windows | Google AI plan names do not supply Google One billing dates. Missing an account-bound next charge and renewal state. |
| Antigravity | Google coding quota windows | No directly identified recurring subscription or billing date in this connection. No renewal pill. |
| OpenCode Go / Zen | Go quotas and Zen credit balance | The connected Console device grant now verifies Go/Go Plus subscriber, current paid period, cancellation and recovery state. Identity and saved credentials are checked around the existing Go status read. Canceled access ends in details; recovery, unknown state and another member stay unavailable. Zen balances and old month anchors remain separate. ([#451](https://github.com/hemsoft-dev/codexbar-ios/issues/451)) |
| OpenRouter | API credit balance | Prepaid/API credits, not a renewing subscription in this integration. No renewal pill. |
| Moonshot | API credit balance | Prepaid/API credits, not a Kimi subscription in this integration. No renewal pill. |
| Greptile | Free-credit allowance renewal | Existing allowance details stay separate. Free accounts get no billing-renewal pill. A paid subscription would need a verified next-charge/auto-renewal contract. |

Unavailable recurring products explain the missing billing date in **More
Information**. Confirmed free or prepaid products have no billing countdown.
Canceled subscriptions show their access end date in details and never say
"Renews". Nothing here requires users to import tokens, cookies or billing dates.

## OpenCode Go billing acquisition

The existing guided device grant needs no separate billing sign-in. The Console
provider checks the saved account credential and `auth/session.user.id` (plus
optional `org_id`) before its existing workspace-scoped Go status request. A
recognized subscriber's billing observation requires a second identity read and
an unchanged saved credential after acquisition. Each optional identity request
has a three-second timeout. A failed optional check drops the billing date while
retaining successfully fetched Go windows and Zen balance. Successful credential
replacement, disconnect, account removal and reset also invalidate cached
OpenCode observations immediately; failed credential writes preserve the cache.

Only explicit, consistent cancellation flags and a currently valid paid access
interval establish a date. Cancellation shows access ending in details. Renewal
requires `resumability: renewing`, `renewalPending: false` and no payment recovery
or stop fields; Go Plus downgrades retain the returned period boundary. Arrays,
unknown products, missing fields and expired intervals remain unavailable. These
reads perform no checkout, portal, cancellation, resume or payment mutation.

The local `OpenCodeSubscriptionBillingTests` intercept production transport and
cover subscriber/workspace/credential isolation, rejected optional access,
malformed billing state, redirect policy and task cancellation after successful
usage. The existing OpenCode verification-failure UI journey captures production
client fixtures on iPhone and iPad. Franz's live account date comparison remains
separate from these synthetic checks.

## Freshness and isolation

Billing observations are transient and bind both local account ID and provider.
ChatGPT requests use the current grant, reject redirects, disable shared cookies
and response caching, and have a three-second budget. The provider checks the
stored credential before and after the request. A returned account ID, when
present, must match the selected ChatGPT account. Access failures, malformed
responses, credential replacement and usage failures clear billing observations;
usage history never restores a previous date. No billing date enters persistent
history, widget or watch snapshots.

A successful observation is fresh for at most 24 hours. The pill updates every
minute and when the card renders after foregrounding, without fetching usage.
It floors full days and hours, then minutes with a minimum of one minute. It
never rolls a passed date into another month. Details retain a labeled last-known
or passed date until refresh replaces it. Date-only observations retain their
civil calendar day across time zones and DST, say "Renews today" on that day,
and disclose that the provider did not supply a charge time. Current ChatGPT
parsing requires an actual ISO-8601 timestamp.

Turning **Show subscription renewals** off hides header countdowns for all
accounts immediately and persists across launches. It does not hide exact
billing details or existing usage-reset dates. An absent saved preference defaults
to on for new installations and upgrades.

## Source evidence and remaining access work

The upstream CodexBar source was inspected at
[`6e118bd`](https://github.com/steipete/CodexBar/tree/6e118bdb5782707bfb0dfd0453d3483e3b216cd0).
Its [OpenAI response parser](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/OpenAIWeb/OpenAISubscriptionMetadata.swift)
uses `active_until` and `will_renew`; its
[dashboard fetcher](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/OpenAIWeb/OpenAIDashboardFetcher.swift)
uses browser cookies. The
[Claude billing client](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeSubscriptionMetadata.swift)
requires a matching web session and organization, and prioritizes cancellation
end dates over residual next-charge fields.

The [Codex Switch request implementation](https://github.com/wen495033653/codex-switch/blob/2965a2e8d6d0737942e7e175951bb471d6816445/src-tauri/src/accounts/usage/client.rs)
and its [live verification notes](https://github.com/wen495033653/codex-switch/blob/2965a2e8d6d0737942e7e175951bb471d6816445/docs/development/subscription-refresh.md)
provide an OAuth acquisition avenue: account query/header, `OpenAI-Beta: codex-1`,
`Originator: Codex Desktop` and a `codex_cli_rs` compatibility user agent. The
notes also report HTTP/2 rejection with their Rust client and success over HTTP/1.1.
iOS uses URLSession protocol negotiation; no private protocol-forcing API or
claim of equivalent live transport behavior is used. Rejected native requests
remain unavailable. Live iOS access must still be checked before calling this
provider supported on Franz's account. If it rejects subscription access, a
public transport solution or guided, account-verified phone billing authorization
flow is still needed. Claude and Grok now have guided, account-verified phone billing connections.
Do not substitute Safari's inaccessible cookies, desktop imports, guessed dates
or a second account's billing session. Live date comparisons and OAuth billing
access verification remain pending for Franz; synthetic tests verify display,
isolation and failure handling, not access to a real subscription.

## Non-Codex acquisition and account isolation (#446)

Claude and Grok use a nonpersistent WKWebView for **Connect Billing** in their
account settings. The user signs in and selects the same provider account;
verification returns to the app automatically. Canceling leaves the usage
connection intact. The session stores only secure, root-path cookies for the
exact provider host in a separate account-specific Keychain entry. Claude keeps
only `sessionKey`. OAuth requests never carry web cookies, and provider web
requests never carry usage OAuth tokens. Neither flow purchases or cancels a plan.

Claude checks `GET api.anthropic.com/api/oauth/profile` with the existing bearer
and `anthropic-beta: oauth-2025-04-20`. Personal `claude_pro`/`claude_max` profiles
must identify `account.uuid` and `organization.uuid`. The web session's
`GET claude.ai/api/account` must identify the same UUID and exactly one matching
membership organization. Web ownership and OAuth ownership are checked again
after subscription details. Organization IDs must be valid UUIDs, never arbitrary
URL paths. Team/enterprise contracts remain unverified.

Grok's read-only first-party client exposes `GET /rest/subscriptions` with browser
credentials. Each returned subscription must identify the current OAuth subject
in `xaiUserId`; a second authenticated observation verifies that ownership is
unchanged. Exactly one active personal subscription with a recognized tier and
one recognized commerce source may supply a date. Provider-reported store data
is accepted only with explicit renewal state and a timestamp. This reads Grok's
account response, not another app's purchase receipts. The existing CLI OAuth
scope (`openid profile email offline_access grok-cli:access api:access`) does not
establish web-cookie access, so no unverified bearer fallback is attempted.

The Grok contract was inspected on October 10, 2026 in the anonymous
[first-party subscription client](https://cdn.grok.com/_next/static/chunks/2_h-917onhidd.js),
SHA-256 `1a25b51f69e656d6c4bcd3cfac2d7e97540913c449a71f2c29a7fb1b15243ade`.
It defines subscription status/tier, `xaiUserId`, Stripe cancellation/period end,
Google renewal/expiry, Apple renewal and top-level billing expiry. This identifies
a viable private web contract; it is not a promise of a stable public API. The
[Grok FAQ](https://docs.x.ai/grok/faq) distinguishes Grok web, App Store, Google
Play and X billing. Claude's [billing FAQ](https://support.claude.com/en/articles/8325618-paid-plan-billing-faqs)
and [cancellation guidance](https://support.claude.com/en/articles/8325617-cancel-your-pro-or-max-subscription)
likewise distinguish provider-managed and store-managed subscriptions.

All reads reject redirects, shared credential storage, caches and inherited
credential headers. Each request has a three-second transport limit. A Claude
refresh performs five reads (at most 15 seconds of transport waits); Grok performs
two (at most six). Reads are optional and performed only after a successful usage
snapshot. Missing/expired billing sessions, access denial, malformed responses,
account changes and optional Keychain read failures return no observation and
leave successful usage intact. Cancellation propagates. Both usage and billing
secrets are compared after the read. Explicit reconnect, credential replacement,
account removal and reset delete the secondary billing secret; normal OAuth
refresh can retain it only when the fresh provider identity still matches.

## Remaining contracts and next actions

[The #447 contract investigation](PROVIDER-BILLING-CONTRACTS.md) records fresh
first-party source hashes, Cursor's discovered cancellation field, the new
OpenCode implementation opportunity, and the exact remaining access gaps.
The table below preserves the initial #446 investigation and its starting points;
the newer investigation supersedes its Cursor and OpenCode contract conclusions.


[Issue #447](https://github.com/hemsoft-dev/codexbar-ios/issues/447) tracks the
following exact gaps. These are **unverified consumer contracts**, not claims
that a provider can never expose renewal dates. No new authorization scopes or
billing mutation endpoints are introduced speculatively.

| Product | Investigated evidence / blocker | Next read-only investigation |
| --- | --- | --- |
| Cursor | The installed official client (workbench bundle SHA-256 `a9157bf9054d3f27a2a6910c855e028bd5e38896fa74405ca2f766abff590cb8`) reads `/auth/full_stripe_profile` with its current bearer. No next-charge field plus explicit cancel-at-period-end contract was found. The current-period usage response lacks that cancellation distinction and can reset monthly on annual plans. | Follow [Cursor's documented Billing flow](https://cursor.com/help/account-and-billing/billing) from its [dashboard](https://cursor.com/dashboard/billing) into Manage Subscription; verify charge date, cancellation state, personal/team ownership and safe guided phone access. |
| Google AI / Google One | Existing Gemini session and Code Assist tier metadata do not expose a verified billing response. Anonymous Google One settings redirect to Google sign-in, so public marketing bundles cannot prove an authenticated contract. [Payments Reseller API](https://developers.google.com/payments/reseller/subscription) is for wholesale partners, not arbitrary existing consumer subscriptions. [Play subscriptionsv2.get](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get) requires publisher authorization, package and purchase token. | Inspect an owner-bound consumer response from [Google payments](https://payments.google.com/) or [Google One settings](https://one.google.com/settings); distinguish direct/Play/App Store/partner subscriptions and match the existing Gemini account. [Google's subscription guidance](https://support.google.com/paymentscenter/answer/9003237) identifies the relevant UI, not an app-readable API. |
| Personal Copilot | Current quota responses lack a next charge and cancellation state. [Published Copilot seat endpoints](https://docs.github.com/en/rest/copilot/copilot-user-management) concern organization administrators and seat settings, not a personal subscription. [GitHub documents](https://docs.github.com/en/copilot/reference/copilot-billing/license-changes) that allowance resets are independent of billing dates. | Verify a personal, account-bound response behind [Billing & licensing](https://github.com/settings/billing), as described in [plan management](https://docs.github.com/en/copilot/how-tos/manage-your-account/view-and-change-your-copilot-plan). Do not reuse organization seat-cancellation dates. |
| OpenCode Go | First-party [console billing component](https://github.com/anomalyco/opencode/blob/7b3d4ce3a7dbd2a6d3637722a0d5f22a7d086937/packages/console/app/src/routes/workspace/%5Bid%5D/billing/billing-section.tsx) calls a server-side Stripe portal action, while [subscription usage logic](https://github.com/anomalyco/opencode/blob/7b3d4ce3a7dbd2a6d3637722a0d5f22a7d086937/packages/console/core/src/subscription.ts) computes usage anchors. Neither establishes a client next-charge/cancellation response. The connected workspace status and Zen balance are insufficient. | Trace the owner/workspace-bound consumer billing response and portal. Require explicit charge/renewal state without a Stripe server secret. Zen prepaid balances remain excluded. |
| Paid Greptile | [Existing research](GREPTILE-USAGE.md) verifies `billing.getState` and `billing.getSubscriptionInfo` for a **free** code-review allowance, not a paid monetary renewal. A legacy API subscription is a different product. Google-backed billing sign-in remains [#409](https://github.com/hemsoft-dev/codexbar-ios/issues/409). | After resolving that auth path, verify a paid organization's code-review billing response with explicit next charge and auto-renew/cancellation state. Keep free allowance periods separate. |

Franz owns real account sign-in, transport compatibility and comparisons against
provider billing pages. Those checks remain pending and do not hold up agent
delivery. Synthetic acquisition fixtures exercise the real clients, provider
parsers and owner checks; they do not establish live provider access.

Verified Go billing remains visible when the independent Zen balance read fails.
Partial-refresh preservation keeps only the fresh account-bound observation; an
old renewal is never reused when the new Go billing state is unavailable.

## Claude renewal acquisition follow-up

[#454](https://github.com/hemsoft-dev/codexbar-ios/issues/454) corrects an app-side
schema rejection. The old parser required all four date aliases, including null
values. The installed first-party Claude **1.49585.0** client treats timestamp
and legacy calendar fields as alternatives, and reads the same organization
`subscription_details` endpoint. The app now accepts absent aliases, keeps strict
validation of present fields, and gives scheduled access endings precedence over
residual next-charge dates. `active` and `trialing` require the returned next
charge; `canceled` never renews. Dates are not calculated from billing cadence,
trial end, invoices, usage resets or plan price. Monthly and annual subscriptions
use the explicit date the provider returns. Paused payment responses remain
unavailable.

Evidence was acquired October 10, 2026 from installed application code only,
not account storage or private responses. Artifacts under
`/Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/`:

| Artifact | Evidence | SHA-256 |
| --- | --- | --- |
| `cab79e57d-BpPIy_mi.js` | `f`/`m` select ending/charge timestamp before the legacy date; optional property access. | `8859f2598fa2fb438860ea755b1e94300e77352161975cbf2fdce2833b392197` |
| `shared-5-BLWkjkBP.js` | `oS` reads organization subscription details; `wS` updates scheduled cancellation before clearing next-charge fields at immediate cancellation. Store/marketplace billing types are distinct. No mutation is used by CodexBar. | `846c07db2a3edb91d44a27f7da188e520833bd42a84a961ee6594ada245f64fc` |
| `c4a931512-Cuy-eKtj.js` | `st` reads nullable date fields. Its billing tool contract identifies UTC timestamps, legacy UTC calendar dates, Stripe status, and null status outside Stripe. | `4d4b568e30cf3524c7018bb8c04ff291143cd881ca9bc89c4824250277a53586` |

This first-party code improves on the older
[upstream parser](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeSubscriptionMetadata.swift),
which also required all aliases. Public
[billing guidance](https://support.claude.com/en/articles/8325618-paid-plan-billing-faqs)
and [cancellation guidance](https://support.claude.com/en/articles/8325617-cancel-your-pro-or-max-subscription)
establish web/store management and paid access through the canceled period;
they do not establish OAuth access to personal billing. Anonymous web acquisition
returned a Cloudflare challenge during this research. That does not establish
whether the guided authenticated phone flow works for Franz.

Claude uses the saved, separately verified billing session on each successful
usage refresh. Missing authorization, expired cookies or HTTP 401, HTTP 403,
identity mismatch, unsupported purchase source, transport failure and rejected
response shape now have distinct account-bound messages. Keychain read failures
produce a retry message instead of claiming that credentials are absent or
belong to a different account. Known Team/Enterprise plans retain the unsupported
explanation and do not offer the personal billing shortcut. More Information offers
**Open Billing Settings** when no date is verified. Settings retain guided
Connect/Reconnect Billing and link to the provider's billing page. The existing
account/organization checks run before and after acquisition. Credential or
session changes discard the observation. Optional billing errors retain usage;
caller cancellation still propagates. No diagnostic contains response bodies,
account identifiers, tokens or cookies. Team/Enterprise and store-managed billing
remain unsupported; the provider's null status cannot become renewal evidence.

Native URLProtocol tests intercept the production Claude provider and billing
client for alternative fields, cancellation, malformed/paused responses, missing
or expired access, denial, store ownership, transport failure, account mismatch,
credential changes and caller cancellation. UI fixtures remain synthetic. Franz's
Max 20X sign-in and comparison with [Claude Billing](https://claude.ai/settings/billing)
are pending owner checks, not an agent delivery prerequisite or claimed pass.
