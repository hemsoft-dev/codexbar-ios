# Grok consumer integration contract

Research for [issue #355](https://github.com/HemSoft/codexbar-ios/issues/355), checked September 23, 2026 EDT. This file records public, unauthenticated evidence and the implementation contract. No personal account, bearer token, purchase, or linking operation was used. Live account and quota comparison remain pending.

The X Subscription account added in [#458](https://github.com/hemsoft-dev/codexbar-ios/issues/458) reuses this sign-in and endpoint; its own field mapping is in [X-SUBSCRIPTION-CONTRACT.md](X-SUBSCRIPTION-CONTRACT.md).

## What the public endpoints establish

- [xAI OIDC discovery](https://auth.x.ai/.well-known/openid-configuration) advertises authorization-code and device-code grants, S256 PKCE, refresh and revocation, userinfo, public-client token authentication (`none`), and `billing:read`. It does **not** advertise dynamic client registration. Neither a supported grant nor a scope name registers CodexBar or establishes permission to read the Grok consumer billing service.
- The [official Grok CLI reference](https://docs.x.ai/build/cli/reference.md) documents `grok login --device-auth`. The [Grok Build source](https://github.com/xai-org/grok-build/blob/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-login/src/config.rs#L245-L255) supplies a public client for its proxy. The project owner explicitly chose the existing Claude/Codex pattern of using this CLI client rather than waiting for a new CodexBar registration. The [CLI's own billing model](https://github.com/xai-org/grok-build/blob/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-shell/src/extensions/billing.rs) defines shared-period percent, financial values, and legacy fields.
- The [consumer FAQ](https://docs.x.ai/grok/faq.md#usage--limits) describes a shared weekly paid-usage pool, a usage percentage and product breakdown in Settings > Usage, a provider-supplied reset, and separately purchased Extra Usage Credits. These do not establish a constant allowance or a percentage for free-tier activity.
- The deployed [web billing adapter](https://cdn.grok.com/_next/static/chunks/2pusluw6cnma7.js) selects `config.creditUsagePercent`, `currentPeriod.type/start/end`, `productUsage`, `prepaidBalance.val`, `onDemandUsed.val`, `onDemandCap.val`, and a separate `billingPeriodEnd`. It maps period enum values to monthly, weekly, or unspecified. This is evidence of a changing first-party web client, **not** a published third-party API contract or proof of the wire encoding.
- `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` with an empty five-byte gRPC-Web message frame, no credentials, and `Content-Type: application/grpc-web+proto` returned HTTP 200 with `grpc-status: 16` and `grpc-message: No credentials presented` on September 23. A POST with an empty HTTP body instead returned `grpc-status: 13` and `Missing request message`. HTTP status alone does not prove a successful RPC. The unauthenticated response included no usage data.
- The [xAI Management API guide](https://docs.x.ai/developers/management-api-guide.md) requires a separate team management key. It does not provide a consumer Grok authorization route. Management and inference credentials are not substitutes for a direct consumer connection.

## Auth and delivery boundaries

1. The phone requests a device challenge from `auth.x.ai` with the public Grok Build CLI client, then opens `accounts.x.ai` using `ASWebAuthenticationSession`. The user chooses and approves an account in the browser. CodexBar polls the device grant, calls OIDC userinfo to verify the subject, and reads `https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the returned bearer token and `x-xai-token-auth: xai-grok-cli`. No pasted credentials, browser cookies, or login on another computer.
2. The [desktop CodexBar investigation](https://github.com/steipete/CodexBar/issues/2812) confirms that the grok.com gRPC-Web endpoint stopped accepting cookie-only auth. A [September 23 desktop PR](https://github.com/steipete/CodexBar/pull/3900) reports a live weekly percent and product breakdown through the CLI proxy on September 22. This is a first-party CLI endpoint, not a published third-party API guarantee. CodexBar must verify consumer response behavior without guessing or counting HTTP 200 alone.
3. Only a verified subject and successfully saved, account-scoped token may establish a connected account. Do not store an identity from an account label. Do not store or transmit live credentials in documentation or tests.
4. Verify refresh, expiry, revocation, cancellation, account selection, and removal. Renewal must keep the same verified subject, and an account replaced or removed during a request cannot regain old credentials or usage.
5. Distinguish absent from present-zero values and validate cents, eligibility, weekly and monthly period boundaries, and unsupported periods. The web adapter normalizes missing monetary values to zero; CodexBar must not invent a usage percentage. Product shares are detail rows, not independent meters; the billing-cycle end is not a usage reset.
6. Keep Cursor Models, Other Models, and `cursor.grok-bot-weekly` under Cursor credentials. Never sum a linked subscription grant with Cursor allowances or infer a Cursor subscription from a Grok link. The [Cursor Bot subscription guide](https://cursor.com/help/grok-bot/supergrok.md) says linked grants do not stack.

## September 24 update: which ledger can the phone verify?

The [consumer FAQ](https://docs.x.ai/grok/faq.md#usage--limits) says paid subscribers receive one weekly pool and can see its percentage, reset and separate Extra Usage Credits in Grok Settings > Usage. The [CLI billing source](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs) forwards `/v1/billing?format=credits` to `GetGrokCreditsConfig`. It reads `creditUsagePercent`, typed `currentPeriod`, `isUnifiedBillingUser`, and `prepaidBalance`. It calls the balance purchased credits, but its *returned* `subscriptionTier` is added from separate [remote settings](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-config/src/remote_settings.rs#L816-L843), not the raw billing JSON. The CLI describes unified billing as a shared pool. This makes the proxy a plausible direct consumer read for entitled accounts, not proof of Franz's live Lite values or a published API guarantee. The app requires an explicit unified-billing flag and an active weekly period before showing the percent; it only shows the balance for an explicit unified-billing user. Missing or unsupported fields stay unavailable except for the narrowly verified omitted-usage case below. The same subject is verified through OIDC userinfo before either read, and cached results remain account-scoped.

## September 24 follow-up: omitted zero and settings encoding

[Issue #363](https://github.com/HemSoft/codexbar-ios/issues/363) reproduced a signed-in CLI proxy response with an active unified weekly period but no `creditUsagePercent`, `productUsage`, or legacy `used` field. The separate settings request succeeded and returned `subscription_tier_display`, not the camel-case key the app originally decoded. The temporary device probe recorded only field presence and types, not tokens, account identifiers, raw responses, balances, or quota values. It was removed after diagnosis. The original live weekly percentage and reset have **not** been compared with Grok Settings > Usage by Franz.

The [first-party CLI display](https://github.com/xai-org/grok-build/blob/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-pager/src/app/effects/helpers.rs#L1580-L1595) uses zero when the percent is absent, even though its [wire model](https://github.com/xai-org/grok-build/blob/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L55-L88) allows the field to be optional. CodexBar applies that convention only when the verified subject's settings name a known paid SuperGrok plan, billing confirms unified billing and an active weekly period, and the response omits the percentage and all alternative included-usage fields. The resulting 0% card says "No included usage reported by Grok." An explicit null or malformed percent, another usage field, an unknown plan, an unsupported period, or a failed settings lookup remains unavailable. Extra Usage Credits are still independent of the weekly meter. This fallback is a first-party CLI convention, not a provider-supplied numeric zero or proof of Franz's live quota.

| Account or ledger | Paid weekly percent / reset | Extra Usage Credits | Plan name and boundary |
| --- | --- | --- | --- |
| SuperGrok Lite | Shared pool if `isUnifiedBillingUser=true` and active weekly period | `prepaidBalance.val` when supplied | Read-only `/v1/settings` `subscriptionTierDisplay` or `subscriptionTier` after userinfo; accept exact known names only. Lite live comparison pending. |
| SuperGrok, SuperGrok Plus, SuperGrok Heavy | Same conditional fields; no invented tier-specific quotas | Same conditional balance | Same [CLI settings and billing sources](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs); no plan from a percent, balance, or login. |
| X-linked benefit | Not assumed to be a paid Grok pool | Not assumed | [Cursor's linked-subscription guide](https://cursor.com/help/grok-bot/supergrok.md) lists X Premium+ as a Cursor grant. A Grok plan name is not inferred from that link. |
| API-only / developer team | No consumer meter without an explicit unified paid weekly response | No consumer balance without explicit unified billing | [xAI Management API](https://docs.x.ai/developers/management-api-guide.md) uses a separate team key and ledger. On-demand, monthly, and product shares are not card meters. |
| Free Grok account | No paid weekly pool without an explicit entitlement | No assumed balance | [Consumer FAQ](https://docs.x.ai/grok/faq.md#usage--limits) describes separate free Chat/Voice limits; never infer a paid tier from CLI authorization. |
| Cursor-linked Grok Bot | Never added to Grok's weekly pool | Never added to Grok credits | [Cursor's guide](https://cursor.com/help/grok-bot/supergrok.md) says grants do not stack and Lite does not qualify. Cursor is its own credential and usage ledger. |

The CLI settings endpoint is optional and may fail or change. No verified tier means the existing account label stays put. A newly generated label is marked as generated so only it may change on a subsequent verified tier; the app never rewrites a custom label. Identical plan names receive unique suffixes per account. Neither UI fixtures nor this public-source analysis establish a live subscription result. Franz owns the comparison of Lite weekly usage/reset and Extra Usage Credits with Grok Settings > Usage; it remains pending.

## October 1 update: inferred usage and zero credits

[Issue #388](https://github.com/HemSoft/codexbar-ios/issues/388) keeps the same
verified-subject, unified-billing, paid-plan and active-period restrictions.
An omitted-usage zero now labels its meter "Weekly usage inferred" and says
that it follows Grok's CLI convention, not a reported measurement. An explicit
numeric zero remains reported usage. Missing, null, malformed, unverified and
unsupported values remain separate unavailable states.

The [pinned first-party Cent model](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/extensions/billing.rs)
explicitly defaults a present empty USD-cents object to zero because proto3
JSON omits zero-valued scalars. CodexBar now accepts that representation for
Extra Usage Credits. Missing or null money and malformed nonempty objects do
not become zero and do not erase an independently valid weekly percent.
This is a source-contract correction, not evidence of Franz's account balance.

The card identifies the consumer billing connection as separate from Cursor
Bot and developer API billing. It creates no linked grant or additional Bot
meter. [Cursor's contract](CURSOR-SPENDING-CONTRACT.md) records its separate
spending fields and the installed first-party evidence for this correction.
The live weekly percentage, reset and balance comparison remains pending.

Before merge, complete local auth/parser regressions and iPhone/iPad UI evidence, plus required checks and reviews. Do not request Franz's credentials.
