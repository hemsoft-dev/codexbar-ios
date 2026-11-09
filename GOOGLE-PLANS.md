# Google subscription pills

The Gemini dashboard shows a Google AI subscription only when the connected
account returns an explicit supported subscription name. OpenCode Go, Zen and
combined cards omit plan pills, including unavailable-plan placeholders.

## Source and mapping

Before each coding quota request, CodexBar makes a `loadCodeAssist` request
to `https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` using that
Gemini account's saved coding OAuth grant, renewed first when it has expired.
The same answer names the account's Cloud Code project for the quota request
(see [ANTIGRAVITY-SETUP.md](ANTIGRAVITY-SETUP.md#quota-contract)) and supplies
the subscription read below, so there is no separate plan lookup. A refresh
normally makes one lookup; when Google rejects the saved token (HTTP 401) and
CodexBar renews it, the lookup runs again with the renewed token, and the plan
comes from that latest answer. The request has an
eight-second request timeout and never sends the Gemini browser cookies.
Rejected or unavailable metadata does not turn valid usage into a failure, and
a failed quota read does not hide a plan the lookup did return. The plan is
dropped when the account's saved coding credential changed during the refresh.

Google's [LoadCodeAssistResponse definition](https://github.com/google-gemini/gemini-cli/blob/9b6e0265d16bbd29ca51e33c9e0c01dc4cec5e83/packages/core/src/code_assist/types.ts)
exposes `paidTier.name` separately from `currentTier` and `allowedTiers`.
CodexBar prefers the assigned paid tier and accepts an explicitly named current
tier only when no paid tier exists. Available upgrades are never subscription
evidence. Generic `free-tier`, `standard-tier`, Workspace and Code Assist
Standard names do not establish a Google One plan.

Supported named subscriptions are Google AI Plus, Pro and Ultra. Google AI Free
is an app display label accepted only when metadata explicitly names free
Google AI access. The older `Gemini Code Assist in Google One AI Pro` naming
maps to Google AI Pro. Explicit Ultra 5x/20x and storage suffixes are preserved;
quota limits, account titles and storage values in other fields cannot create
those suffixes. Unknown values show Plan unavailable.

The [Google AI plan comparison](https://one.google.com/intl/en_us/about/google-ai-plans/)
was checked on 2026-10-10. Franz's supplied reference shows Pro 5 TB, Pro 10 TB,
Plus 400 GB/2 TB, and Ultra usage variants. These references establish display
names, not the subscription of any connected account.

## Availability and account isolation

Apps-only accounts currently have no verified subscription source in the
existing Gemini Usage RPC. They remain Plan unavailable. Generic coding free
access is also insufficient to establish free Google One access. Some Google
accounts may return a tier ID without a supported name; CodexBar does not guess
its name or multiplier. Additional authenticated metadata would be needed to
identify these cases, not manual plan selection or exported credentials.

Plan results require an unchanged account credential identity across refresh
and an unchanged coding credential across the metadata request. Identity hashes
use the account ID, browser credential and renewable coding grant; credentials
are never rendered or persisted in those hashes as plain text. A failed or
unknown lookup clears the plan. Cached quota data may remain stale, but it does
not preserve a former plan. Credential invalidation clears the plan immediately.

Synthetic unit and UI fixtures cover supported names, variants, unknown states,
account isolation and OpenCode header visibility. They do not prove the contents
of Franz's live account response. Live account comparison remains Franz-owned.
