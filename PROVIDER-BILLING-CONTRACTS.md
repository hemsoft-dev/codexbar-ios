# Remaining subscription billing contracts

Research for [#447](https://github.com/hemsoft-dev/codexbar-ios/issues/447),
acquired October 10, 2026. This records evidence for consumer billing reads;
it does not add provider support. [Subscription billing dates](SUBSCRIPTION-RENEWALS.md)
describes the shipped connections.

A usable contract needs a read-only acquisition flow, an account and subscription
identifier, an explicit future charge or canceled access-end date, and renewal
state. A usage period, plan name, invoice or missing cancellation value is
insufficient. Public documentation proves only the interface it describes;
private client source proves the fields that client consumes, not live iOS access.

## Decision register

| Product | Verified evidence | Remaining gate | Classification |
| --- | --- | --- | --- |
| Cursor | Native sign-in successfully reached the authenticated web profile and customer-bound Stripe portal subscription on October 15, 2026. | Franz's phone sign-in and live date comparison; unsupported subscription variants remain unavailable. | Private contract acquired and implemented in [#456](https://github.com/hemsoft-dev/codexbar-ios/issues/456), with [current evidence](CURSOR-BILLING.md). |
| Google AI / One | Consumer billing pages and store/partner distinctions; publisher and reseller API access boundaries. | Consumer response, account/payer binding and a supported phone authorization-to-data flow. | Private consumer contract unverified; published publisher/reseller APIs inapplicable to this lookup. |
| Personal Copilot | Personal billing UI, cancellation semantics and public personal usage APIs. | Product-specific next charge and cancellation response tied to the authenticated GitHub user. | Private consumer contract unverified; documented usage/seat APIs insufficient. |
| OpenCode Go / Go Plus | Current console read schema, workspace bearer middleware, subscriber ID, explicit cancellation, paid period and recovery state. | Franz's separate live compatibility check. | Implemented private client contract in [#451](https://github.com/hemsoft-dev/codexbar-ios/issues/451); synthetic production-client coverage, live account compatibility pending. |
| Paid Greptile | Current first-party client exposes code-review cancellation/status fields. | Paid next-charge semantics, paid response schema and supported fresh Google billing authorization. | Partial private contract; [#409](https://github.com/hemsoft-dev/codexbar-ios/issues/409) remains open. |

These classifications are specific to the inspected interfaces. They do not claim
that a provider can never expose billing data. OpenCode is the verified implementation opportunity. The other four products
still need the exact evidence described below; no speculative integration issues
were opened for them.

## Cursor

The initial findings below record the earlier desktop-only investigation. The
October 15 API probe closed its owner and billing-state gaps. The implemented
route and current limits are documented in [Cursor subscription billing](CURSOR-BILLING.md).

### Source revision and acquisition

Inspected the installed official Cursor **3.22.7**, release commit
`37076c6c3f9e253c0fa2305197e45befd13a2260`, dated September 24, 2026. Source file:
`/Applications/Cursor.app/Contents/Resources/app/out/vs/workbench/workbench.desktop.main.js`.
SHA-256:
`a9157bf9054d3f27a2a6910c855e028bd5e38896fa74405ca2f766abff590cb8`.
Only application code and public product metadata were read; no local account
storage, token or cookie was inspected. The hash pins a local first-party artifact,
not a publicly hosted source repository.

The official [billing documentation](https://cursor.com/help/account-and-billing/billing)
identifies [Cursor Billing](https://cursor.com/dashboard/billing) → **Manage Subscription** →
Stripe portal. Anonymous HTTP reads of the dashboard and its `www` equivalent
returned 403 during this acquisition; this is an observation of this request,
not evidence that authenticated access is impossible. Marketing assets from
[Cursor](https://cursor.com) are not the authenticated dashboard contract.

### Read contract and cancellation discovery

The bundle's `fetchFullStripeProfile` uses **GET**
[`/auth/full_stripe_profile`](https://api2.cursor.sh/auth/full_stripe_profile) with the current Cursor bearer.
`getRawAuthFetchHeaders` also supplies client type/version, privacy/onboarding
headers, a trace identifier, and **optional `x-cursor-team-id`**. No new billing
OAuth scope is established by this source. It uses the current Cursor credential.

The `refreshMembership` callsite consumes these response fields:

- `membershipType`, `subscriptionStatus`;
- `lastPaymentFailed`, `paymentRecoveryAction`;
- **`pendingCancellationDate`**, a nonempty string interpreted as a date.

This corrects the earlier research boundary: the official client **does have
explicit pending-cancellation evidence**. Its billing-banner helpers `rF_`,
`wBh` and `pF_` validate a future parseable date and present it as a plan-ending
date. It is a cancellation/access-end signal, not a future payment promise.
Missing or empty `pendingCancellationDate` defaults to no banner in that client;
it does **not** prove affirmative auto-renewal. `lastPaymentFailed` and a mandate
reauthorization action prevent treating an active membership as a guaranteed
next charge. The inspection did not establish the complete response schema or
its account/customer/subscription identifiers.

The same bundle declares the read-only Connect RPC
[`DashboardService/GetPlanInfo`](https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo)
(`GetPlanInfoRequest` is empty) with this **source-derived shape, not a captured
live response**:

```text
planInfo?: {
  planName: string
  includedAmountCents: integer
  price?: string
  billingCycleEnd?: int64
  planOwner: UNSPECIFIED | STRIPE | APPLE
}
nextUpgrade?: { tier, name, includedAmountCents, price, description }
```

The UI labels this `billingCycleEnd` as **"Usage limits reset on"**. Neither this
message nor `GetCurrentPeriodUsage` includes a cancellation/auto-renew Boolean.
`planOwner` identifies a commerce source, **not the user's identity**. Combining
an absent cancellation string with a reset boundary would still guess renewal.
The official [billing guide](https://cursor.com/help/account-and-billing/billing)
distinguishes monthly/yearly subscription renewal and monthly individual usage.

### Ownership, stores and next step

The official client derives its account identity from bearer JWT `sub`, checks
that identity before/after membership refresh and discards a result after a
session change. A selected team header changes request context. A consumer
implementation must establish whether its billing result is personal or belongs
to that team and bind any returned customer/subscription to the connected account;
JWT `sub` alone does not prove the billing response's owner.

[Cancellation guidance](https://cursor.com/help/account-and-billing/cancel)
separates Stripe, Apple-managed iOS and Google Play-managed Android purchases.
Team billing requires an administrator. Canceled direct plans retain access until
the paid period ends. The `planOwner` enum inspected above has no Google Play
value; that message cannot be assumed to cover every commerce source.

**Next step:** obtain a first-party authenticated dashboard/portal response schema
or provider-confirmed read interface showing next charge, affirmative renewal,
pending cancellation and personal/team customer binding. Trace the portal launch
request and identity response without purchasing, canceling or embedding a Stripe
server key. Replay those verified fields in isolated transport fixtures before
opening an implementation issue. Cursor's cancellation field is useful partial
progress, but does not close the monetary-renewal gap.

## Google AI / Google One

### Consumer flow and independently observed access boundary

The [payments-center guide](https://support.google.com/paymentscenter/answer/9003237)
points to [Google payments](https://payments.google.com/) → **Subscriptions & services** → product
**Manage**. It includes automatic payments, manual prepayments and invoicing;
a listed service is not automatically a recurring subscription. Google One
settings are at [Google One settings](https://one.google.com/settings).

Anonymous acquisition of One settings redirected to `accounts.google.com`.
Payments redirected to `/payments/home`, whose HTML contained a JavaScript
redirect to Google sign-in. The Play consumer subscriptions page,
[Play subscriptions](https://play.google.com/store/account/subscriptions), also redirected to sign-in.
No owner-specific subscription payload was exposed by those anonymous pages;
no authentication was attempted. Sign-in markup is not a billing response schema.

### Public APIs that cannot supply this consumer lookup

The [Payments Reseller Subscription API](https://developers.google.com/payments/reseller/subscription)
is a partner wholesale platform. Its existence does not authorize reading a
consumer's unrelated retail subscription.

[Play `purchases.subscriptionsv2.get`](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get)
reads
`GET https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{packageName}/purchases/subscriptionsv2/tokens/{token}`
and requires the `https://www.googleapis.com/auth/androidpublisher` scope, the purchased
app's package and its purchase token. The
[getting-started guide](https://developers.google.com/android-publisher/getting_started)
requires Play Console permissions; user OAuth does not bypass those permissions.
CodexBar is not the publisher of Google One and has no purchase token from it.
Adding that scope to a consumer Google sign-in would not make this a viable
acquisition path. The API's explicit expiry/renewal fields demonstrate a publisher
contract, not permission to discover another app's purchases.

[StoreKit transactions](https://developer.apple.com/documentation/storekit/transaction/all)
cover purchases **for the calling app**. CodexBar cannot enumerate Google One's
Apple purchases through its own StoreKit transaction sequence.

### Phone authorization and owner binding

Google's [native OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app)
explicitly rejects OAuth authorization in `WKWebView`; use its supported browser
or SDK flow. A private embedded billing sign-in cannot be considered verified
merely because Claude/Grok use one. Supported Google OAuth establishes access to
consented APIs, not export of Google payments web cookies. A browser login alone
also does not return an authenticated billing payload to CodexBar. No billing
consumer OAuth scope or equivalent session transfer was verified here.

The existing Gemini/coding tier identifies benefits, not the payer. A future
contract must expose an immutable Google account identifier that can be matched
to the connected Gemini identity, plus the billing subscription/payer identifier.
Email hints, `authuser` indices and a family-shared plan name do not establish
ownership. This identity requirement is an implementation constraint, not a claim
that such identifiers were found in the protected response.

### Direct, store and partner distinctions

[Google One cancellation guidance](https://support.google.com/googleone/answer/9056360?hl=en)
separates Play and Apple billing and family-member access. Normal cancellation
retains benefits through the paid cycle; a stated carrier exception ends benefits
immediately. A member receiving another person's benefits is not necessarily the
billing owner.

[Partner subscription guidance](https://support.google.com/googleone/answer/15801606?hl=en)
assigns plan/payment management to the partner. It also describes an Apple plan
continuing when a partner plan activates, creating possible concurrent billing.
A single effective Google AI tier therefore cannot prove one recurring purchase.

**Next step:** acquire a first-party consumer contract for direct Google payments
or One settings with explicit renewal/cancellation, billing channel and stable
Google/payer/subscription identity. Establish a provider-supported mobile flow
that returns those reads to the app. Keep Play, Apple and partner subscriptions
unavailable unless the consumer/provider contract reports their actual billing
state. Multiple subscriptions, family grants, prepaid offers and immediate partner
cancellation must have distinct fixtures. No owner sign-in is needed to finish
this public contract investigation; live verification remains separate.

## Personal GitHub Copilot

### Published contracts and source revision

The official [personal plan guide](https://docs.github.com/en/copilot/how-tos/manage-your-account/view-and-change-your-copilot-plan)
locates plan controls under Billing & licensing → Licensing (new platform), or
Plans and usage (original platform). Cancellation preserves access through the
cycle; organization-assigned or complimentary access is a different entitlement.
The [license-change guide](https://docs.github.com/en/copilot/reference/copilot-billing/license-changes)
states that included allowances reset on the calendar month independently of
subscription billing. Neither a quota reset nor membership entitlement proves a
personal charge.

The public [personal billing usage API](https://docs.github.com/en/rest/billing/usage)
now provides these **GET** endpoints with **Plan user permission: read**:

```text
/users/{username}/settings/billing/ai_credit/usage
/users/{username}/settings/billing/premium_request/usage
/users/{username}/settings/billing/usage
/users/{username}/settings/billing/usage/summary
```

They report historical metered usage and cost, not a personal subscription's next
charge or auto-renewal. This is more precise than saying all GitHub billing APIs
are organization-only. Their published response includes `timePeriod`, `user`
and `usageItems`; there is no next-charge or subscription cancellation field.
The review also checked organization seat schema: `pending_cancellation_date`
belongs to an organization's seat, not a personal consumer renewal.

These schema observations were reproduced from GitHub's
[first-party OpenAPI description](https://github.com/github/rest-api-description/blob/58b1e0c00b39b9e46c24dc4a0ba6a2669c90e9c1/descriptions/api.github.com/api.github.com.json),
revision `58b1e0c00b39b9e46c24dc4a0ba6a2669c90e9c1`, SHA-256
`da3d22e417611cca9a4131dceea89d4d61c3be021b0917f32d9e4422e4fe60f1`.
The inspected billing usage and Copilot seat paths contain no personal renewal
endpoint. This is a boundary of that published schema, not proof about every
GitHub private interface.

### Private UI, identity and next step

An anonymous request to [GitHub Licensing](https://github.com/settings/billing/licensing) redirected
to GitHub login. The historical `/settings/billing` request returned 404 in this
acquisition; the currently documented Licensing route reached a sign-in page.
Its public
[`settings-e6e0fedf40fcbe31.js`](https://github.githubassets.com/assets/settings-e6e0fedf40fcbe31.js)
asset (SHA-256
`3793c2c5366694815e4a4262db707d99b01b6fce7d66e6e35102dad8309b9f89`)
contains settings interactions but no verified personal renewal/cancellation read.
That sign-in page exposes no authenticated personal billing payload to verify. No
personal cookies or private account billing data were read.

A future guided GitHub billing session must verify immutable GitHub user `id`
against the usage connection and distinguish personal subscriptions from
organization seats, trials, free grants and other licensed products. Inspecting
`GET api.github.com/user` identity would not itself supply billing state. The
existing `GET api.github.com/copilot_internal/user` usage response has no verified
next-charge/cancellation pair; do not widen its grant speculatively.

**Next step:** trace the authenticated Licensing page's first-party read response
or obtain a GitHub-confirmed personal subscription API. Require a product-specific
subscription ID, future charge, explicit pending cancellation/access end and the
same immutable GitHub account owner. Keep account-level invoice dates and
organization-seat cancellation out of the personal pill. Only after documenting
that response and replaying isolation/cancellation/access-failure fixtures should
an implementation issue be opened.

## OpenCode Go / Go Plus

### Current console supersedes the older billing investigation

The old [billing component](https://github.com/anomalyco/opencode/blob/7b3d4ce3a7dbd2a6d3637722a0d5f22a7d086937/packages/console/app/src/routes/workspace/%5Bid%5D/billing/billing-section.tsx)
wraps a server-side Stripe portal action. Its
[billing service](https://github.com/anomalyco/opencode/blob/7b3d4ce3a7dbd2a6d3637722a0d5f22a7d086937/packages/console/core/src/billing.ts)
creates a portal session with the provider's Stripe secret and customer ID.
That creation is a POST that creates an object, not a read-only subscription
lookup. CodexBar must not acquire a Stripe server secret or invoke checkout,
cancellation, resume or payment actions for a countdown.

At that same revision, `generateLiteCheckoutUrl` reports that Go has moved to
the new console. Its old
[Go query](https://github.com/anomalyco/opencode/blob/7b3d4ce3a7dbd2a6d3637722a0d5f22a7d086937/packages/console/app/src/routes/workspace/%5Bid%5D/go/lite-section.tsx)
returns usage derived from local creation/month anchors, not monetary renewal.
The current [Go documentation](https://dev.opencode.ai/v2/docs/console/go)
describes Go and Go Plus for single-member workspaces. The older source therefore
cannot settle the new console's response contract.

Anonymous navigation to the [current console](https://opencode.ai/console/)
reached its login page; `GET /console/auth/session` returned 401. No sign-in
was attempted. Anonymous first-party JavaScript fetched in the collaborative
browser returned 200 and supplied the new contract:

| First-party asset | SHA-256 | Evidence |
| --- | --- | --- |
| [index-DYCaqV0g.js](https://opencode.ai/console/assets/index-DYCaqV0g.js) | `146e37b2d3f51ce2213e19123487c64268c6d022d1a887d0eeacb92514c40af6` | JSON response schema, bearer workspace middleware, device-grant schema and `x-org-id` scope header. |
| [app-pages-eYfbMrPk.js](https://opencode.ai/console/assets/app-pages-eYfbMrPk.js) | `82879a776b6c44152d83a128f0a5a7ef6d46cbb159e8cb3f0fa3edc530492753` | GET Go status route, subscriber checks and renewal/access-end/payment-recovery display. |

The bundle paths pin this deployment, not a stable public API. Command-line
anonymous requests returned 403 in this environment; successful browser reads
establish source acquisition, not native bearer acceptance on a live account.

### Read, authentication and ownership

```text
GET https://opencode.ai/console/auth/session
Authorization: Bearer <existing device-grant access token>

GET https://opencode.ai/console/api/go/status
Authorization: Bearer <same access token>
x-org-id: <connected workspace ID>
```

The first-party route uses `WorkspaceMiddleware` with bearer security, and its
client supplies the scope through `x-org-id`. The existing native
[device flow](CodexBarIOS/Services/OpenCodeDeviceAuthService.swift) uses
`client_id: codexbar-ios`, `supports_org_scope: true`, the device-code grant,
refresh token and returned `org_id`. It already verifies `auth/session.user.id`
and calls this same Go status endpoint with the same workspace header.
No new billing scope or private web session is required by the inspected route;
server-side grant compatibility remains Franz's live check.

Bind the selected local account, token, workspace and `subscriberUserId`.
The current first-party Go controls compare that subscriber to the session
user before allowing subscriber actions. Do not confuse display names, a
workspace member or the old `mine` Boolean with a stable billing owner.
Verify `auth/session` before and after acquisition, reject a conflicting
returned `org_id`, and compare saved credentials again after the read. The
session parser uses `user.id` and optional `org_id`, ignoring unrelated metadata.
These
repeated reads are the native isolation policy, not a claim that the
web client itself makes them in that order.

The following is a source-derived JSON field shape. No live Go subscription
response was captured; example identifiers and dates in the replay are synthetic.

```text
null | {
  subscriberUserId: string,
  product: "go" | "go-plus",
  renewalProduct: "go" | "go-plus",
  cancelAtPeriodEnd: boolean,
  resumability?: "renewing" | "resumable" | "needs-payment-method"
                | "access-ended" | "revoked" | "unknown",
  renewalStopReason?: string,
  renewalPending: boolean,
  renewalAuthorizationRequired?: boolean,
  renewalRetryAt?: timestamp,
  renewalPaymentAttemptId?: string,
  access: null | {
    startsAt: timestamp,
    endsAt: timestamp,
    cancelAtPeriodEnd: boolean,
    meters: { fiveHour, week, month }
  }
}
```

The schema decoder maps internal `subscriberUserID` and
`renewalPaymentAttemptID` to the JSON names ending in `Id`. Dates decode from
strings to valid dates. The current consumer response is a nullable single
subscription, not an array. Reject any future array or ambiguous product shape.

### Monetary meaning and precedence

The console explicitly presents `access.endsAt` as renewal when access exists,
no cancellation is scheduled and recovery is not required. It presents the same
paid boundary as access ending when `cancelAtPeriodEnd` is true. It separately
shows pending payment, authorization, retry and paused states. The implementation
should require consistent top-level/access cancellation flags, a valid current
paid interval, affirmative `resumability: renewing` and `renewalPending: false`
before saying Renews. Reject unknown or stopped renewal, authorization required,
retry timestamps and payment attempts. A canceled valid paid period is access
ending even if residual recovery fields exist. Contradictory state supplies no date.

Go Plus may switch to Go at this boundary without ending the subscription.
Expose its actual date, not a derived monthly quota reset. Null access, past
periods, free/trial grants, Zen balances/automatic credit reload and unsupported
store product shapes never supply a monetary countdown. No Apple/Play billing
path is established by this contract.

### Fixture proof and implementation follow-up

Run the local-only [contract replay](scripts/research/opencode-billing-contract.py):

```sh
python3 scripts/research/opencode-billing-contract.py
```

Three test methods cover 34 synthetic cases. They check the exact GET paths,
bearer/header scoping, optional workspace fields, extra session metadata,
identity changes, other subscribers, Go/Go Plus and
downgrade, arrays/multiple subscriptions, cancellation precedence/contradiction,
missing/malformed/past dates, unknown/store products, payment recovery and
optional access failure. The fixture reader intercepts every request in memory;
there is no network, credential acquisition or billing mutation. This validates
a proposed policy against the source-derived fields, not production Swift code,
provider authentication or a real charge.

[Implementation issue #451](https://github.com/hemsoft-dev/codexbar-ios/issues/451)
tracks production parsing/transport, account isolation, existing renewal
presentation/preference, native focused fixtures, iPhone/iPad screenshots and
signed phone delivery. This research PR does not add support or require a new
build. The future implementation must test the production client and retain
honest unavailable states when native access is denied.

## Paid Greptile

The current [billing guide](https://www.greptile.com/docs/code-review-bot/billing-seats)
identifies organization Billing and a portal for plan status and cancellation.
[Published MCP tools](https://www.greptile.com/docs/mcp-v2/tools) expose account,
review and analytics operations, but do not document monetary renewal. API keys
bind their own organization; OAuth organization selection does not create
billing access.

Navigating the [billing dashboard](https://app.greptile.com/-/settings/billing)
reused the already signed-in browser session, with no new login or billing
action. Only its public JavaScript was inspected; no private account payload,
cookie, token, invoice or paid subscription was collected. An independent
anonymous HTTP navigation reached Greptile login. The older usage bundle URL
recorded in [GREPTILE-USAGE.md](GREPTILE-USAGE.md) now returns 404, so it was not
used to claim current paid support.

| First-party asset | SHA-256 | Evidence |
| --- | --- | --- |
| [0q6e-jhubnb-o.js](https://app.greptile.com/_next/static/chunks/0q6e-jhubnb-o.js) | `bb00f763b37b6753af963a8fe4a5c7b364cf68d9ae307aa0f6b688d139908578` | `getSubscriptionInfo` and `getState`; code-review status, `scheduledToCancel`, `cancelAt`, `periodStart` and `periodEnd`. |
| [2aqujtgpg3mgf.js](https://app.greptile.com/_next/static/chunks/2aqujtgpg3mgf.js) | `5b94a9ae4100677424ed4b7051f9c0741c8b3ac36ff567a4e99885465e7284bb` | Organization-scoped reads and invoice/usage display using `codeReview.periodStart`/`periodEnd`. |

The read transport remains `GET /api/trpc/billing.getSubscriptionInfo` and
`GET /api/trpc/billing.getState`, each with the selected `tenantExternalId` in
`tRPC` JSON input. The current billing client separates `codeReview` from other
products. Its cancellation display prefers `cancelAt`, then `periodEnd`, and
marks past-due/unpaid states separately. This is new partial cancellation
contract evidence. It does not establish an actual future-charge timestamp or
a complete paid schema. In particular, `periodEnd` is also used to label review
usage and invoices. The client warns that charges can still accrue before a
scheduled cancellation. Cancellation does not imply a guaranteed zero final bill.

The historically verified read authenticates with a dashboard cookie and
verifies `auth/session` subject plus organization membership. The October 5
OAuth probe established identity access but not dashboard billing access.
The [#409 update](https://github.com/hemsoft-dev/codexbar-ios/issues/409#issuecomment-6080569108)
confirms the approved support request was sent on October 9. Its exact missing
capability remains a provider-supported read-only billing OAuth grant or secure
native dashboard-session exchange for fresh Google-backed sign-in. The issue
has no recorded provider reply at this acquisition. No new external support
message was sent for #447.

Next obtain the supported authorization response through #409, then an explicit
paid code-review contract from Greptile showing organization/subscription owner,
next charge, renewal/cancel status and access end. Distinguish standard and
legacy plans, multiple subscriptions, paid/trial/free, overdue recovery and
optional denial before opening an implementation issue. A free allowance's
period and the legacy API product cannot supply a paid monetary renewal. A paid
plan purchase is not required to finish this research.

## Validation limits and disposition

OpenCode was the only implementation opportunity found in this investigation.
Its isolated replay passes; #451 now integrates that contract into the production
Console provider with native transport and rendered simulator coverage. Live
account compatibility remains pending for Franz.
The remaining providers have no verified acquisition/schema pair to replay as
a renewal implementation. Invented JSON fixtures would not remove those gaps.
Their next steps specify the missing fields, authorization and owner checks so
a future verified response can be tested before implementation.

No app source, native test suite, workflow, automatic CI trigger/job/timeout or
required check is changed. The research replay is manual-only and is not wired
into GitHub Actions. No full release UI validation was dispatched. Production
usage, quotas and shipped renewal coverage remain unchanged. Live provider
sign-in and comparisons belong to Franz and remain separate from this research.
