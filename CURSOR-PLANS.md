# Cursor subscription names

Subscription renewal acquisition now uses an account-bound Stripe portal read
through the existing sign-in. See [Cursor subscription billing](CURSOR-BILLING.md)
for its verified contract, cancellation rules and unsupported states. The usage
membership lookup described below remains independent of optional billing.

Cursor's current-period usage response carries counters, not a subscription
identity. CodexBar uses an optional, account-scoped
`GET https://api2.cursor.sh/auth/full_stripe_profile` request with the same
Bearer access token as the usage requests. It reads the top-level
`membershipType` string; no price, allowance or account label determines a tier.

## Contract evidence

Checked October 10, 2026 against the installed first-party Cursor 3.22.7 client,
obtained through [Cursor's official download](https://cursor.com/downloads).
Its `out/vs/workbench/workbench.desktop.main.js` defines `fetchFullStripeProfile`
with this GET endpoint and `getRawAuthFetchHeaders` with Bearer authorization.
`refreshMembership` consumes the response's `membershipType`, rejects results
when the current auth identity changes, and stores membership under that identity.
The client enum explicitly defines `pro` and `pro_plus`; its account UI renders
these as `Pro` and `Pro+`.

The [official pricing page](https://cursor.com/pricing) confirms public names
Hobby, Pro, Pro+, Ultra, Teams Standard/Premium and Enterprise. Pricing supplies
names only; it is never used to classify an account. The authenticated browser
dashboard redirects signed-out requests to WorkOS; no live account response was
captured during development. Tests replay synthetic responses matching the
first-party wire shape. Franz owns live account comparison.

| Raw membershipType | Pill |
| --- | --- |
| `pro` | Pro |
| `pro_plus` | Pro+ |
| `ultra` | Ultra |
| `free` | Hobby |
| `free_trial` | Pro Trial |
| Missing, malformed, unknown | Plan unavailable |

The installed client also has `pro_student`, `enterprise` and `express` enum values. Its team
flow uses `enterprise` for both Team and Enterprise, distinguished by additional
team information. CodexBar therefore leaves that ambiguous value unavailable;
it does not label a team as an Enterprise subscription. Start and Teams
Standard/Premium are not mapped without a verified distinguishing field.

## Failure and account handling

The plan request is optional and has a five-second task deadline. HTTP errors,
malformed responses and timeouts yield no plan while preserving current usage.
It shares the isolated session's no-cookie/no-cache/redirect rejection policy.
There is no separate plan cache or manual plan picker. The existing result cache
can preserve a last-known plan after a primary usage failure only when the
account and credential identity match. Fresh usage with unavailable metadata
shows Plan unavailable rather than retaining a possibly obsolete subscription.

After all responses arrive, the provider rechecks the saved credential. A late
response after replacement or removal is discarded. Relaunch fetches membership
again using the securely saved credential. Guided phone sign-in remains intact.
