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
| Claude | Provider-owned billing access; automatic web-session acquisition paused | Personal Pro/Max/Ultra settings and More Information offer **View billing in Claude** at the fixed provider billing URL. It may open a browser or provider app; neither the destination nor date availability is promised. New embedded Connect/Reconnect and automatic reuse of saved Claude billing cookies are disabled. Saved bytes remain until explicit Disconnect. Quota/plan retrieval is unchanged, which does not establish provider permission. No new renewal observation is produced. Team/Enterprise have no personal shortcut. Store guidance is unconditional. |
| Cursor | Existing phone sign-in, authenticated web profile and customer-bound Stripe portal subscription | Personal Stripe subscriptions supply an actual paid period end and explicit cancellation flags. Monthly/yearly observations require matching owner, customer, product and interval with no recovery or pending changes. Canceled access ends in details. Team, trial, unsupported or rejected billing stays unavailable. `billingCycleEnd` remains only a quota boundary. See [acquisition evidence and safety rules](CURSOR-BILLING.md). |
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
flow is still needed. Grok retains its guided billing connection. Claude uses provider-owned billing access as described below.
Do not substitute Safari's inaccessible cookies, desktop imports, guessed dates
or a second account's billing session. Live date comparisons and OAuth billing
access verification remain pending for Franz; synthetic tests verify display,
isolation and failure handling, not access to a real subscription.

## Non-Codex acquisition and account isolation (#446)

Claude's new and reconnecting embedded billing flows are unavailable. **View billing in Claude** is primary in eligible personal account settings and More Information. It opens the fixed https://claude.ai/settings/billing URL without creating a session or treating return as successful authentication. Team/Enterprise and unrecognized/free plans receive no personal shortcut. Guidance always explains that purchases through Claude for iOS or Android are managed through the purchase store, without inferring the account's payment platform. Claude for iOS also exposes profile > Billing.

The default SubscriptionBillingClient stops Claude connect, fetch and fetchClaudeObservation before reading saved billing bytes, checking billing-profile ownership or issuing web requests. This is a reversible capability reduction: users with previously functioning saved sessions no longer receive automatically refreshed Claude billing observations. The bytes are preserved. **Disconnect saved billing** remains explicit and deletes only that account's billing key. Usage authorization and retrieval are unchanged, not approved by this decision. Existing bound date, cancellation, freshness and account rules remain; cached observations are not stamped as newly verified on browser return.

[Current provider guidance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) describes restrictions; no applicable exception or permitted consumer billing handoff was established. Council supplies no provider permission and this is not a breach/compromise/legal finding. [The usage-auth qualification follow-up](https://github.com/hemsoft-dev/codexbar-ios/issues/548) separately tracks client identity and permission before a future release. The absolute release hold remains. No outreach, key creation, account probe or silent usage quarantine is part of this change.

The old Claude parser and pre/post account/organization checks remain available only through explicitly injected DEBUG synthetic URLProtocol contract clients. There is no production environment switch that enables saved Claude web-session reuse. Those tests establish contract handling, not live access or a supported Google connection.

Grok keeps its existing private WebKit connection, secure root-host cookie capture, six-local-read/15-second discovery budget, credential equality, account verification, non-wiping Reload, explicit wiping Start Over and Cancel. Its Google destination policy and other provider flows are unchanged. No cookie export, external callback bridge or personal service is introduced.

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
credential headers. Each request has a three-second transport limit. The historical Claude
contract performs five reads only under explicit synthetic injection; Grok performs
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

The November 2 recurrence of [#454](https://github.com/hemsoft-dev/codexbar-ios/issues/454)
remains reported, not reproduced on Franz's live account. A production-provider
regression identified a separate compatibility gap: plan resolution accepted
explicit `claude_ultra`, while the billing client's personal-plan allowlist
rejected it before reading subscription details. Billing now accepts the same
explicit personal family. It still requires the saved same-account session,
matching OAuth/web account and organization before and after acquisition, and
an actual provider charge date. No date is inferred from the Ultra name.

`xcrun swift test --filter ClaudeSubscriptionRenewalTests` exercises the real
Claude provider, isolated billing transport, parser and bound presentation data.
The pre-fix explicit-Ultra case returned `unsupportedSubscription` with no
countdown; the Pro/Max controls succeeded. The fixture is synthetic compatibility
coverage, not proof that a live account returns `claude_ultra` or that this was
Franz's cause. Legacy Max 20x metadata remains supported. The existing personal
session, stale-state, ownership, cancellation and transport rules remain intact.

The focused manual `testClaudeUltraReportedWindowsEvidence` capture also loads
an explicit-Ultra billing response through the production provider and real
dashboard before capturing the renewal pill and exact date in both appearances.
Live acquisition and comparison on Franz's account remain unverified; the issue
must retain that gate independently of synthetic success and phone installation.

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

The historical Claude web contract is paused at every production billing entry point. Its parser and identity tests retain synthetic coverage for alternate fields, cancellation, malformed/paused data, denied/store responses, account/organization mismatch and stale credentials. The new production-path regressions verify no saved billing read, no Cookie/claude.ai or billing-profile request, unchanged synthetic saved bytes and useful usage. Native settings/More Information captures and the isolated URL-opening journey prove the fixed provider action, no embedded sign-in and no false connection/date after return. They do not prove where iOS resolves the link, the provider page content or the actual account's billing result.

All seven live renewal/blank-page outcomes under #454 remain pending. This provider-owned viewing fallback only partly answers the request; it does not acquire the missing in-app renewal pill or exact date. The prior phone-install clarification remains complete.
