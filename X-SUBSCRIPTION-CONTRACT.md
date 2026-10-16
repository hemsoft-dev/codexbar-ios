# X Subscription integration contract

Research for [issue #458](https://github.com/hemsoft-dev/codexbar-ios/issues/458), checked October 16, 2026 EDT. This file records public first-party evidence for The X Subscription, the plan xAI and Cursor launched on [October 12, 2026](https://x.ai/news/x-subscription). No personal account, bearer token or sign-in was used. Unauthenticated probes only observed error shapes. No live response from a unified account has been captured, so the live comparison is still pending for Franz.

**Reported** means the field exists in a first-party wire model or client. **Inferred** means it follows from first-party code or docs but has not been seen in a live response.

Sources:

- [grok-build `2bdd1d6`](https://github.com/xai-org/grok-build/commit/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8). This is still the latest `main`, from September 29. Nothing has landed since the launch, and `billing.rs` last changed on September 15.
- grok.com web chunks fetched October 16.
- The installed Cursor client 3.24.12 (`workbench.desktop.main.js`).

## Plans and what "unified" means

- The X Subscription sells Grok, Grok Bot, Cursor and X Premium as one plan: Free, Plus, Premium, Super and Ultra ([overview](https://docs.x.ai/x-subscription/overview), [Cursor overview](https://cursor.com/help/the-x-subscription/overview)).
- Existing SuperGrok, Cursor and X Premium subscribers keep their plans. [Unifying](https://docs.x.ai/x-subscription/unify-accounts) is optional and can't be undone.
- On a unified account, Grok Bot "counts against the same shared weekly pool" ([Cursor models and pricing](https://cursor.com/docs/models-and-pricing), [usage limits](https://cursor.com/help/models-and-usage/usage-limits)). Prepaid credit is separate and doesn't reset ([prepaid balance](https://docs.x.ai/x-subscription/prepaid-balance)).
- `isUnifiedBillingUser` on the Grok CLI billing response is **not** the X Subscription flag. It marks the June 2026 shared Grok pool and comes from the remote setting `unified_consumer_billing_enabled` ([GROK-CONSUMER-CONTRACT.md](GROK-CONSUMER-CONTRACT.md)).

## Grok Settings > Usage on legacy and unified accounts

grok.com builds the weekly label as "Weekly {tier} Limit" ([2yabghdhqqcj0.js](https://cdn.grok.com/_next/static/chunks/2yabghdhqqcj0.js), [1a0__q2vbtb77.js](https://cdn.grok.com/_next/static/chunks/1a0__q2vbtb77.js)).

For a unified ("commerce") subscription, the tier is the unified plan name from `UNIFIED_PLAN_NAMES`:

| Legacy plan | Unified plan |
| --- | --- |
| SuperGrok Lite | Plus |
| SuperGrok | Premium |
| SuperGrok Plus | Super |
| SuperGrok Pro | Ultra |

The separate "Weekly Grok Bot Limit" card is hidden when `session.user.cursorMerged === true` and the account is not a team account ([2bskf1280aa7m.js](https://cdn.grok.com/_next/static/chunks/2bskf1280aa7m.js), [1g3shofkfp9fv.js](https://cdn.grok.com/_next/static/chunks/1g3shofkfp9fv.js)).

**Inferred:** the October 16 capture attached to #458 shows "Weekly SuperGrok Limit" and a separate "Weekly Grok Bot Limit". That is a **legacy, non-unified** account. A unified account shows **one** weekly pool, labeled with its unified plan name, plus Extra Usage Credits. It shows no separate Grok Bot window.

## Field mapping

| Metric | Endpoint and auth | Field path | Status |
| --- | --- | --- | --- |
| Weekly pool percent and reset | Grok CLI proxy `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (forwards to `GetGrokCreditsConfig`), xAI device-auth bearer token | `config.creditUsagePercent`, `config.currentPeriod.{type,start,end}`. There is one `currentPeriod`, with no list of limits and no periods per product. | Reported ([billing.rs#L55-L96](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L55-L96), web proto in [3ms27m40eqfmc.js](https://cdn.grok.com/_next/static/chunks/3ms27m40eqfmc.js)). Values for unified accounts not captured. |
| Share of the pool by product | Same response | `config.productUsage[].{product,usagePercent}`, with no period. The `billing_product.Product` enum is `API` (1), `GROK_BUILD` (2), `GROK_PLUGINS` (3), `GROK_CHAT` (4), `GROK_IMAGINE` (5), `GROK_VOICE` (6), `GROK_APP_BUILDER` (7), `GROK_TASKS` (8), `GROK_BOT` (9), `CURSOR` (10) and `BUGBOT` (11), named `PRODUCT_*` in proto JSON. The web client clamps non-finite or non-positive shares to 0. | Reported in the web proto. The CLI doesn't read it ([test note](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/extensions/billing.rs#L599)). [#363](https://github.com/hemsoft-dev/codexbar-ios/issues/363) saw it omitted. |
| Extra Usage Credits | Same response | `config.prepaidBalance.val`, in USD cents | Reported. The sign convention conflicts: web clamps with `max(0, …)` ([00cd1bc6g3tng.js](https://cdn.grok.com/_next/static/chunks/00cd1bc6g3tng.js)), while the CLI pager uses `abs()` and says billing stores negative cents ([credit_bar.rs#L345-L358](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/src/views/credit_bar.rs#L345-L358)). |
| Plan tier (xAI) | `GET https://cli-chat-proxy.grok.com/v1/settings`, same bearer token | `subscription_tier_display` (for example "SuperGrok", "X Premium+" or "Free"), set from the token's tier claim | Field reported ([remote_settings.rs#L816-L843](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-config/src/remote_settings.rs#L816-L843)). Values for unified plans are **unknown**. |
| Grok Bot weekly limit (legacy only) | grok.com WebSocket `wss://grok.com/ws/bot/`, JSON-RPC `bot.usage`, browser session | `usagePercent`, `currentPeriodStartMs`, `nextResetAtMs`, `hasNonZeroIncludedLimit`, `includedLimitZero`, `isTeamSeat`, `planLabel`, `onDemandEnabled` | Reported ([bot_relay.rs#L377-L421](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/common/xai-tool-protocol/src/bot_relay.rs#L377-L421), [0ifsc7dwwvoj4.js](https://cdn.grok.com/_next/static/chunks/0ifsc7dwwvoj4.js)). There is no bearer-token path for it. |
| Grok Bot weekly limit through Cursor | `DashboardService/GetSandUsageStatus`, already read by the Cursor provider | `usage_percent`, `next_reset_timestamp_utc`, plus new fields `is_unified`, `billing_brand` (CURSOR or GROK), `grok_plan_label`, `cursor_plan_name` and `unified_billing_url` | Fields reported (Cursor client). That it is the same backend as `bot.usage` is inferred. What it returns for unified accounts is unverified. |
| Unified flag (Cursor) | `DashboardService/GetPlanInfo`, Cursor session | `plan_info.is_merged`, `plan_name`, `included_usage_period` (WEEKLY or MONTHLY), `included_usage_resets_at`. The editor switches to its unified display when `isMerged && !enterprise`. | Reported (Cursor client) |
| Unified pool (Cursor) | `DashboardService/GetCurrentPeriodUsage` | `plan_usage.total_percent_used`, with the reset from `GetPlanInfo` | Reported (Cursor client) |
| Credits (Cursor) | `DashboardService/GetUserPrepaidBilling {limit: 1}` | `available_cents`, `funded_cents`, `spent_cents`, `spent_this_month_cents`, `billing_mode` | Fields reported. That this is the same xAI balance is inferred (the request carries `xai_team_id`). |
| Third-party model spending | None | Not reported separately. The unified editor display hides the split between auto and API models. Credit spend and `spend_limit_usage.individualUsed` combine overage with third-party use. The editor says "Non-Grok usage and usage beyond limits consumes additional usage." | Not reported |

`DashboardService/GetXaiUserUsageSnapshot` returns the pool, product usage and `prepaid_balance_cents`. An unauthenticated probe returned `unauthenticated: "Invalid xAI identity assertion"`. It needs an internal xAI assertion that a phone app can't obtain, so CodexBar must not use it.

## Implementation contract

1. One sign-in. The X Subscription account reuses the guided xAI device authorization from [GROK-CONSUMER-CONTRACT.md](GROK-CONSUMER-CONTRACT.md): the browser opens on the phone, the user picks the account and the app reads the userinfo subject. That one sign-in covers the weekly pool, its reset, Extra Usage Credits and the plan tier. It does not ask for a Cursor sign-in.
2. One weekly meter. Show `creditUsagePercent` and `currentPeriod` once, only for an active weekly period. Never add `productUsage` shares together, and never show them as separate meters. They are detail rows that describe how the one pool was used.
3. Credits stay separate from the pool. Show `prepaidBalance.val` as a balance only when it is a non-negative value, the same rule the Grok provider uses. A negative value stays unavailable until a live capture settles the sign convention. A present empty object is the proto3 zero. Missing, null or malformed values stay unavailable and never become zero.
4. Plan names. Accept only the documented unified names (Plus, Premium, Super, Ultra), matched exactly and case-insensitively, optionally prefixed "X Subscription". A bare "X" prefix is not accepted, because "X Premium" and "X Premium+" are legacy X tiers, not unified plans. **Inferred:** which of these strings `/v1/settings` returns for unified accounts is unconfirmed (see Open items). Any other tier, or a failed settings read, leaves the label unchanged and the plan pill unavailable without blocking the pool or credits. A tier is never inferred from a percentage, balance or sign-in. A legacy SuperGrok tier name does not mean the account is not unified: grok.com maps SuperGrok Lite, SuperGrok, SuperGrok Plus and SuperGrok Pro to Plus, Premium, Super and Ultra in its own client, so the backend may report the legacy name for a unified account. Such a tier leaves the plan pill unavailable and never hides the pool or credits.
5. No third-party spending meter. No first-party endpoint reports Cursor's third-party model spending separately on a unified account, so the card doesn't invent one.
6. Legacy accounts keep their current behavior. Separate Grok and Cursor accounts keep their reads, metric IDs (`grok.*`, `cursor.grok-bot-weekly`), history, layout, widgets and Watch output. Legacy plans aren't being discontinued, so no metric is hidden or dropped on a legacy account. When `GetSandUsageStatus.is_unified` is explicitly true on a saved Cursor account, the Cursor card keeps every metric it shows today, including `cursor.grok-bot-weekly`, and only adds a pointer to an X Subscription account. Whether that endpoint reports the shared pool on merged accounts is unverified, and team seats keep a separate Grok Bot limit. When `/v1/settings` reports a recognized unified plan name on a saved Grok account, the Grok card likewise keeps its data and adds the same kind of pointer. CodexBar never moves or deletes a saved account on its own.
7. Do not log tokens, account identifiers or live usage values, or write them into fixtures, docs or tests.

## Implementation notes

- `ProviderID.xSubscription` (`xSubscription`) reuses `GrokDeviceAuthService`, `GrokCredential`, the credential lock, subject verification and refresh. Grok's SuperGrok billing sign-in is not offered, because its parser rejects X-derived subscriptions.
- Metric IDs: `xSubscription.weekly-pool` for the pool and `xSubscription.monetary.balance.usd` for Extra Usage Credits. Product shares appear only in the `xSubscription.product-usage` information section, and only when the pool bar is shown.
- `isUnifiedBillingUser` is not required for the X Subscription pool. Grok's omitted-percent zero convention applies only when the verified tier is a recognized unified plan.

## Open items

- The `subscription_tier_display` and `GetPlanInfo.plan_name` values for unified Plus, Premium, Super and Ultra accounts.
- Whether `isUnifiedBillingUser` is true for merged accounts, and whether `productUsage` appears through the CLI proxy.
- What `GetSandUsageStatus` returns for merged accounts: the shared pool or nothing.
- The wire sign of `prepaidBalance.val`.
- A live comparison with Grok Settings > Usage on a unified account. Franz owns it and it is still pending. Unifying is irreversible, so a live capture should not be produced by unifying a test account without Franz's decision.
