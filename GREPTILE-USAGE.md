# Greptile review activity and billing allowance

The October 3, 2026 investigation for [#395](https://github.com/HemSoft/codexbar-ios/issues/395)
used first-party public documentation. The October 5 follow-up for
[#406](https://github.com/HemSoft/codexbar-ios/issues/406) verified read-only
billing and identity responses in an existing authenticated dashboard session.
No review, upgrade or billing action was triggered. Secrets and private review
history are excluded from this document.

## Current app behavior

Google-backed fresh billing login and reconnect remain unavailable. The
[October 29 public-contract recheck](#google-backed-billing-login-october-29-2026)
found no supported billing OAuth grant or native dashboard-session exchange.
Account settings explains this before sign-in. Google authorization links in
the temporary browser stop at a recovery screen, with Return to sign-in and
Cancel actions. Another method is useful only if it already belongs to that
Greptile account. The app never recommends changing the account's login method
or opening Safari as a way to transfer its session.

Issue [#406](https://github.com/HemSoft/codexbar-ios/issues/406) adds guided
Greptile sign-in on the phone. A private, temporary browser session opens
[Greptile Usage](https://app.greptile.com/-/settings/usage), verifies the signed-in
identity and organization membership, and asks which organization to connect.
Only that account's Auth.js session cookie or numbered cookie chunks are saved
in its Keychain entry. Canceling leaves saved credentials unchanged. Reconnect
must match the saved user and organization; another identity requires a separate
CodexBar account. Reconnecting while the prior credential is saved preserves
history only when the verified user and organization match. After Disconnect,
the prior identity is no longer available to compare, so signing in clears the
old history after the new verified credential is securely saved, even for the
same user. Existing API-key accounts keep their review history and offer an Add
Greptile account button, since their user identity cannot be verified.
Unrelated cookies do not reset account selection. A changed auth cookie is
reverified while the chooser stays visible; an expired or invalid identity
clears the prior chooser. Connection cannot finish with a pending cookie change.
The browser session is discarded after connection or cancel.
HTTP 401 and 403 responses reject connection before credentials are saved.
Canceling a fresh attempt leaves it unconnected; canceling reconnect preserves
the saved credential, selected organization and review history. Existing saved
dashboard sessions can still refresh through the account-verifying reader.

The app reads `GET /api/auth/session` with the saved session to re-verify identity
and membership before every billing read. It then reads
`GET /api/trpc/billing.getState?batch=1&input=...` on `app.greptile.com`, passing
`{"0":{"json":{"tenantExternalId":"<selected organization>"}}}` as URL-encoded
input. These dashboard requests use the account's cookie, bypass shared cookie
storage and HTTP cache, and reject redirects. The authenticated dashboard
contract was verified on October 5, 2026; it is not a published public API and may
change. See the verified contract below.

For `kind: "free"`, `result.data.json.currentPeriod.end` supplies the allowance
renewal date. Counts are not required. A returned start, when present, must be a
valid date earlier than the end. The countdown updates each minute and shows the
local calendar date, time and time zone alongside the countdown on both
dashboard widths and in More Information. Larger accessibility text can wrap
without truncating either value. Review-history subtitles and explanatory
footnotes are omitted. Missing or malformed dates offer
[Greptile Usage](https://app.greptile.com/-/settings/usage). A date past its period
asks for refresh; observations older than a day or preserved after a failed
refresh are labeled last known. A successful refresh replaces the period.
A failed or unrecognized billing response does not classify a new account as
free; a matching saved plan classification survives that failure. Malformed
billing clears the date while retaining that classification. More Information
can dismiss its sheet and open guided account settings to reconnect. The
reconnect action keeps CodexBar in the foreground.

[Issue #429](https://github.com/hemsoft-dev/codexbar-ios/issues/429) adds a separate
`greptile.credit-allowance` metric for a valid free billing state. It reads the
reported numeric `used` and positive `includedCreditsPerPeriod`, shows their
percentage and exact credit values, and calculates remaining included credits
as `max(included - used, 0)`. More Information lists used, included and remaining
credits. Credit history has its own series, separate from review history.
Exhaustion and over-allowance usage retain the actual used amount.
Neither completed reviews nor a fixed 50-credit assumption supplies these values.
Missing, malformed, boolean, negative or non-finite values remain unavailable;
a missing, invalid, ended or future-starting period cannot become current usage.
Renewal may still be available when the credit counts are absent. Paid billing
states do not create this free-credit metric, and API-key behavior is unchanged.
This uses the internal dashboard contract already verified above; it does not
establish fresh Google sign-in, which remains tracked in
[Issue #409](https://github.com/hemsoft-dev/codexbar-ios/issues/409).

Review activity remains a separate metric with its existing IDs and saved
visibility, order and width. The verified session's user token authorizes
read-only MCP activity calls, scoped with the selected organization. Existing
organization API-key accounts retain review activity and can add a separate
account through guided sign-in to obtain billing renewal. The dashboard and
More Information label this migration "Add Greptile account"; it is separate
from reconnecting an expired browser session. No credit balance is inferred from
review counts, and no calendar boundary is guessed.

Local synthetic tests and simulator journeys validate app behavior. Live phone
sign-in and comparison with Franz's Greptile account remain his verification
step, not evidence supplied by the synthetic tests.

## Original October 3 conclusion

Greptile's [pricing page](https://www.greptile.com/pricing) lists Starter as
Free with **50 credits per month**, one active developer and unlimited
repositories. That entitlement is real public product information. It is not
an account-specific used or remaining balance.

The [published MCP tools](https://www.greptile.com/docs/mcp-v2/tools) do not
document an allowance, remaining-credit balance or billing-period reset tool.
The app currently calls `list_code_reviews`, whose documented response contains
review activity, not billing usage. Consequently, the app cannot establish
Franz's remaining Free allowance from that published response contract.

This does **not** prove that Greptile has no private billing endpoint or never
returns optional billing fields. The reference provides examples and prose,
not exhaustive closed schemas. We did not probe private endpoints or inspect
an authenticated account response. A new supported billing API would require
its own verified contract before integration.

The app now explains that the connection shows review history rather than
remaining credits. Empty activity with no billing fields is unavailable
billing data, not a zero balance. Existing explicit returned review quotas
remain supported without changing numeric identity, values or reset dates.

## Credits are not a count of PRs

According to [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats)
and [Review tiers](https://www.greptile.com/docs/code-review/review-tiers):

- Base costs 1 credit, Plus 3 and Apex 10. Billing separately lists T-Rex
  reviews at 3 credits. Fifty credits therefore do not guarantee fifty reviews
  at every tier. Whether each tier is available on a particular Starter
  account was not verified.
- Completed review runs count toward billing, not unique PRs. Skipped reviews
  do not count. Multiple completed runs on the same PR can incur multiple
  charges, including automatically triggered runs.
- PR reviews are charged to the PR author, not the person who triggered them.
  Included credits and flex usage are per developer, not a shared team pool.
- Attributed CLI reviews share the user's seat allowance. Unattributed CLI
  reviews are flex usage. API-key reviews are unattributed unless the key is
  bound to a user with a linked account.

The pricing page says "per month" and billing documentation says "per billing
period." Neither source supplies this account's current period, reset date,
time zone, rollover or proration. Do not assume a first-of-month reset or
subtract all-history completed reviews from 50.

## What the documented tools establish

| Source/tool | What it supplies | What is not documented |
| --- | --- | --- |
| `list_code_reviews`, `get_code_review` | Review IDs, statuses, timestamps, PR information and progress metadata | Charged credits, actual allowance, remaining credits, billing-period reset |
| `get_me` | Credential principal, reachable organizations and roles | Plan entitlement or credit balance |
| Analytics tools | Review/findings metrics, selected time ranges, rankings and repository/author filters | Billing balance, entitlement or authoritative billing-period boundaries |

All three rows are from the
[Tools Reference](https://www.greptile.com/docs/mcp-v2/tools). Review strictness
metadata is not a credit price. An analytics date filter is not proof of a
billing period. Repository visibility may also restrict activity counts.

The reference states that an API key is bound to its own organization and
ignores OAuth tenant arguments/headers. It does not document an additional
billing-allowance scope for these tools. Changing account selection or adding
permissions cannot be promised to reveal fields absent from the published
contract. Authentication failures remain distinct from a successful response
that lacks billing data.

## App contract and compatibility

`CodexBarIOS/Services/GreptileUsageProvider.swift` makes a read-only
`list_code_reviews` tools call through `https://api.greptile.com/mcp`. This HTTP
POST is JSON-RPC transport, not a request to trigger a review.

- Complete, deduplicated review activity remains labeled **Completed reviews**
  under **All available review history**. Missing billing data never creates a
  50-credit gauge, a dollar balance, a Free badge or a guessed reset.
- Optional explicit `reviewsUsed` plus positive `includedReviews` or equivalent
  review-named fields still produce **Reviews used** for **Current billing
  period**. This is compatibility behavior, not a claim that the published
  MCP schema includes those fields or that they measure credits.
- Credit-named fields are not silently treated as review counts. Malformed,
  Boolean or non-positive allowance values cannot create a quota.
- Existing stable keys, account-scoped credentials, saved metric/widget/Watch
  choices and pagination/truncation limits remain unchanged.
- Provider/authentication errors remain errors. Successful missing billing data
  is not evidence of a rejected key and does not call for repeated sign-in.

[Usage](https://app.greptile.com/-/settings/usage) and
[Billing](https://app.greptile.com/-/settings/billing) are the provider's documented
human-facing account views. The documentation does not turn these web pages
into a supported API. Do not scrape sessions, export browser credentials,
require manual balances, trigger paid reviews or buy a plan to validate this
integration. Live same-account comparison remains with Franz; it is not an
agent delivery prerequisite.

## Reproducing the investigation

Run the local-only regression target:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --filter GreptilePaginationTests
```

`GreptileAllowanceRegressionTests` drives the production provider through an
isolated URL protocol. It covers activity without billing fields, empty
activity, credit-looking/malformed metadata, explicit returned review quota
and reset, and authorization failure. The first two clarity assertions failed
against the original messages before the fix. Existing pagination regressions
remain in the same local-only target; automatic native test counts are unchanged.

The manual `GreptileAllowanceUITests` journey drives the same production
transport/parser through an intercepted synthetic endpoint on iPhone and iPad.
Its activity fixture supplies hypothetical 12-of-50 credit-named metadata. With
no supported credit contract, that metadata must not become a quota or plan.
It checks dashboard copy, review statuses and account metrics, empty activity,
a hypothetical returned review quota, and provider failure. Its quota fixture
is deliberately 3 of 17 **reviews**, not an assumed real Free allowance.
The journey also forces the iPad simulator menu-relaunch workaround on both
families. That hook refreshes through the real provider before asserting sheet
content, rather than presenting a preconstructed or empty result.
Every other network request is blocked. See [UI testing](UI-TESTING.md) for the
focused command and release-only full-run guard.

## Remaining uncertainty

The live account's actual balance and billing boundaries were not verified.
Starter-specific trial transitions, overage behavior, tier availability and
undocumented runtime fields are not established by this investigation. The
safe current result is review activity plus an explicit unavailable billing
balance, not a fabricated approximation of the provider's allowance.

## Paid-plan follow-up, October 5, 2026

Research for [#397](https://github.com/HemSoft/codexbar-ios/issues/397).
The October 3 findings above remain a historical record. This follow-up checked
current first-party plan, billing, MCP, permissions and public API documentation
without accessing a paid account.

**A supported paid-plan code-review billing API is not verified.** The reviewed
sources do not establish an endpoint, tool, optional billing field or permission
that buying Pro or Enterprise unlocks. They also do not explicitly rule out
such an integration. Missing public documentation cannot establish that paid
plans never expose balances. The source ledger below records what was checked.

| Classification | Finding and evidence |
| --- | --- |
| Supported | [Pricing](https://www.greptile.com/pricing) documents Pro at $30 per seat per month, with 50 code-review credits per seat per month and $1 additional credits. Enterprise has custom pricing and includes Pro features. These are plan terms, not account consumption fields. |
| Supported | [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats) documents per-developer included credits and flex usage, plus human-facing Usage and Billing dashboards. [Review tiers](https://www.greptile.com/docs/code-review/review-tiers) assigns Base 1 credit, Plus 3 and Apex 10. These billing rules do not supply an account balance API. |
| No explicit denial | No reviewed first-party source explicitly denies billing API access for all Pro or Enterprise subscriptions. No universal unsupported classification is justified. |
| Not verified | A supported read-only contract for consumed code-review credits, remaining allowance, plan eligibility or account billing-period/reset timestamps was not found in the reviewed [MCP reference](https://www.greptile.com/docs/mcp-v2/tools), [billing](https://www.greptile.com/docs/code-review-bot/billing-seats) or [plan documentation](https://www.greptile.com/pricing). Paid or negotiated Enterprise access remains unanswered. |

### Access and product boundaries

The [MCP setup guide](https://www.greptile.com/docs/mcp-v2/setup) documents OAuth
at `https://api.greptile.com/mcp`. The
[tools reference](https://www.greptile.com/docs/mcp-v2/tools) documents OAuth
organization selection and organization-bound API keys, plus review history,
account discovery and analytics. It does not document billing scopes or
paid-only balance fields. Its examples are not closed schemas.
[Organization settings](https://www.greptile.com/docs/account/organization-settings)
describes Enterprise custom roles, but does not identify a billing-read API
permission. This does not prove that changing roles or authentication reveals
a credit balance.

Code-review credits must remain distinct from any codebase-query or other API
allowance. The [current public documentation index](https://www.greptile.com/docs/llms.txt)
does not list a standalone codebase API contract. The former public
[query](https://www.greptile.com/docs/api-reference/query) and
[search](https://www.greptile.com/docs/api-reference/search) documentation URLs
redirected to the introduction; the
[repositories](https://www.greptile.com/docs/api-reference/repositories) and
[OpenAPI](https://www.greptile.com/docs/openapi.json) URLs redirected to a docs
login page rather than returning public API specifications. Those redirects
establish a research limitation, not API removal or paid-plan eligibility.
No login was attempted. No separate API unit, allowance, current billing schema
or relationship to code-review credits was verified. Do not import an API-query
quota into the code-review balance or rely on a third-party OpenAPI copy.

The [billing page](https://www.greptile.com/docs/code-review-bot/billing-seats)
describes credits per billing period and organization flex caps. It does not
provide this account's boundaries, reset timestamp or time zone, or an API
contract for them. An analytics date range remains a caller-selected range,
not an authoritative billing period.

### Source ledger

Every entry was checked on October 5, 2026. Conclusions apply to the published
material retrieved that day; there is no provider support confirmation.

| First-party source | Evidence checked | Checked |
| --- | --- | --- |
| [Pricing](https://www.greptile.com/pricing) | Starter, Pro and Enterprise terms; no advertised billing API entitlement | 2026-10-05 |
| [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats) | Credit attribution, flex limits, Usage/Billing dashboards, support contact | 2026-10-05 |
| [Review tiers](https://www.greptile.com/docs/code-review/review-tiers) | Credit units vary by review tier | 2026-10-05 |
| [MCP tools](https://www.greptile.com/docs/mcp-v2/tools) | Account, review, knowledge-base and analytics contracts; no documented credit balance or reset tool | 2026-10-05 |
| [MCP setup](https://www.greptile.com/docs/mcp-v2/setup) | OAuth setup and tenant selection; no documented billing scope | 2026-10-05 |
| [Organization settings](https://www.greptile.com/docs/account/organization-settings) | Enterprise roles and review permissions; no documented billing-read API permission | 2026-10-05 |
| [Documentation index](https://www.greptile.com/docs/llms.txt) | Public documentation inventory; no standalone API specification listed | 2026-10-05 |
| [Query](https://www.greptile.com/docs/api-reference/query), [search](https://www.greptile.com/docs/api-reference/search) | Redirected to introduction | 2026-10-05 |
| [Repositories](https://www.greptile.com/docs/api-reference/repositories), [OpenAPI](https://www.greptile.com/docs/openapi.json) | Redirected to docs login; no public schema retrieved | 2026-10-05 |

### Provider questions and next step

The exact questions requiring Greptile confirmation are:

1. Does Pro, Enterprise or a negotiated deployment expose a supported read-only
   API or MCP tool for **code-review** credits consumed, included allowance,
   remaining credits and flex usage? What is its published, versioned contract?
2. Which plans and deployments qualify? Which OAuth scopes, API-key permissions
   and organization/user roles are required? Does the response describe the
   organization, an individual developer or unattributed usage?
3. What are the exact field names and units? How do tier charges, promotional
   credits and flex usage affect them, and are codebase API allowances separate?
4. Does it return authoritative period start/end and reset timestamps? What are
   the time zone, rollover, proration and reporting-delay semantics? Is fetching
   the data read-only and free of review charges or account changes?

The [billing documentation](https://www.greptile.com/docs/code-review-bot/billing-seats)
names support@greptile.com for billing questions and sales@greptile.com for
Enterprise pricing. No message was sent. Recommendation: preserve the current
review-history behavior; do not recommend purchasing a plan to enable CodexBar
credit tracking on this evidence. No supported implementation opportunity was
verified, so no billing-integration follow-up is proposed yet. If Greptile
supplies a supported contract, open a separate implementation issue before
changing transport, parsing or UI.

Paid-account runtime comparison remains **pending for Franz**, not an agent
delivery prerequisite. A later authorized read-only comparison should record
only redacted field names, units, scope and behavior against the same account's
dashboard. No upgrade, purchase, billable review, private-endpoint probe,
billing-session scrape or exported credential was used for this investigation.

## Starter renewal API investigation, October 5, 2026

Research for [#406](https://github.com/HemSoft/codexbar-ios/issues/406), after
the request to investigate beyond published MCP documentation. **A renewal
boundary for the actual free 50-credit allowance is available through the
signed-in dashboard API.** The earlier investigations did not inspect that
response and do not establish that a renewal date is impossible to retrieve.

### Verified dashboard read contract

The normal [Usage dashboard](https://app.greptile.com/-/settings/usage) loads
`billing.getState`, `billing.getCodeReviewBillingPeriods` and
`billing.getSubscriptionInfo` through its tRPC read transport. After normal
sign-in, the existing HemSoft session returned HTTP 200 for this standalone
read, without an Authorization header:

```text
GET https://app.greptile.com/api/trpc/billing.getState
    ?batch=1&input=<URL-encoded JSON below>

{"0":{"json":{"tenantExternalId":"<selected-organization-external-id>"}}}
```

The tRPC response is an array. The provider result is under
`[0].result.data.json`, with the following confirmed fields. This example
redacts the account's numeric usage and timestamps; it is a shape description,
not a literal fixture or complete response:

```json
{
  "kind": "free",
  "includedCreditsPerPeriod": 50,
  "used": "<returned numeric usage>",
  "coveredAuthorLimit": 1,
  "entitlements": ["CODE_REVIEWS"],
  "currentPeriod": {
    "start": "<provider ISO 8601 timestamp>",
    "end": "<provider ISO 8601 timestamp>"
  }
}
```

`currentPeriod.end` is the provider's current free-credit period boundary.
It is usable as the next renewal date without guessing a calendar rule.
The Usage page derives its current-period label from this same state.
`billing.getCodeReviewBillingPeriods` returned matching `startTime` and
`endTime`; `billing.getSubscriptionInfo.codeReview` also returned matching
`periodStart` and `periodEnd`. The state itself identifies `kind: free` and
50 included credits, so the conclusion does not depend on interpreting a paid
subscription. The separate legacy API-product subscription period differed
and must not be used for code-review renewal.

These procedures were observed in the site's own requests before being read
independently. The [first-party Usage client](https://app.greptile.com/_next/static/chunks/app/%28main%29/%28app%29/%5BtenantId%5D/%5Bnamespace%5D/settings/usage/page-3b7e8e0246253aca.js)
confirms organization-scoped inputs and preference for `getState.currentPeriod`
when choosing the current usage range. The bundle path identifies the inspected
deployment; it is not a stable API or application dependency.

### Authentication and public API boundaries

The successful tRPC request used the existing same-origin browser session.
The session's Greptile token, supplied as Bearer authorization with browser
cookies omitted, returned HTTP 401 `UNAUTHORIZED` from the same billing read.
That is a result for this session token, not proof that every API key or OAuth
token is rejected. API-key access to this route remains unverified.

The token successfully authorized the official CLI's
`GET https://api.greptile.com/v1/me`. The raw server response contained only
identity, email and memberships, with no billing field. The CLI's validator
strips unknown fields, so inspecting the raw response was necessary.
The [official CLI repository](https://github.com/greptileai/cli/tree/7ecf571512567faf3cf496775ee131468a45c03a)
points to the [published 3.6.1 package](https://registry.npmjs.org/greptile/3.6.1),
whose bundled source was inspected without installing or executing it.
The [tarball](https://registry.npmjs.org/greptile/-/greptile-3.6.1.tgz) SHA-256
is `0f7db04d1e614fe51846e50ad07930d75137cd670f54b4bce2502dc5fb7895ea`.

An authenticated read-only `tools/list` request to
`https://api.greptile.com/mcp` returned 21 tools, matching the
[fixed first-party catalog](https://github.com/greptileai/codex-plugin/blob/7227d753ae64efe571fd3e9d1a139d2e24bd4102/chatgpt-app-submission.json).
No tool in that live catalog exposes billing or renewal. The public
[OAuth resource metadata](https://api.greptile.com/.well-known/oauth-protected-resource)
establishes read/write scopes, not a separate billing-read grant.

The distinction is now concrete. A first-party internal dashboard API returns
the free renewal boundary. A supported public API-key or MCP billing contract
has not been established. Native integration must provide a normal guided
sign-in and securely retain account-scoped authorization. It must not require
users to copy cookies, export credentials, enter dates, or buy a plan. Verify
which authentication the native client can retain and use before selecting
its transport; do not claim that an API key supplies this response.

### Existing quota notices as corroboration

GitHub's [pull-request review API](https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request)
also exposes provider-authored quota messages without triggering another review.
Greptile's [open-source quota notice](https://github.com/designedbyomar/designedbyomar/pull/101#pullrequestreview-5420549724)
names October 17 as an automatic resume date after 100 repository-level credits
were exhausted. Another [open-source notice](https://github.com/kwilson21/kaillera-next/pull/38#pullrequestreview-5332627493)
names October 20. Those are different allowances and cannot supply the Starter
renewal date. The prose omits the year, time and time zone.

Eight sampled [free-50 notices](https://github.com/ashraftown/pingstats/pull/22#pullrequestreview-5420659823)
reported exhaustion without a renewal date. The notice itself does not name
Starter; the [pricing page](https://www.greptile.com/pricing) supplies that plan's
50-credit entitlement. The 39 indexed HemSoft PRs with Greptile reviews were
also checked, covering 690 review records. Their exhaustion notices, including
[CodexBar PR 114](https://github.com/HemSoft/codexbar/pull/114#pullrequestreview-5402317998)
and [HS Buddy PR 632](https://github.com/HemSoft/hs-buddy/pull/632#pullrequestreview-5097510720),
did not supply dates. Publication times are not renewal times. Search coverage
is limited by GitHub's index and repository visibility.

### Delivery status

The authenticated dashboard contract and live MCP catalog were verified on
October 5, 2026. Only normal read requests were used. No review was triggered,
credits consumed, purchase made, billing setting changed, or secret printed.
Private account identifiers and session credentials are excluded from these
notes. Account-specific timestamps and a dashboard capture are retained only
in local research evidence.

This finding supersedes the earlier lack of an authenticated renewal contract.
The app now implements guided account-scoped authentication, renewal parsing
independent of the credit balance, missing/stale-date handling, and dashboard
and detail-sheet presentation. A development build has been installed and
launched on the connected iPhone. Franz's live sign-in and same-account value
comparison remain pending.

### Compatibility check

Inspection of `makeReviewsRequest` and `reviewQuota(in:)` in
`CodexBarIOS/Services/GreptileUsageProvider.swift` confirms the request still
calls only `list_code_reviews`. Optional explicit review-named used/allowance
pairs retain their existing period fields and stable identity. Credit-named
metadata is not a review quota. The synthetic fixtures in
`GreptilePaginationTests/GreptileAllowanceRegressionTests.swift` exercise that
compatibility and missing-data behavior; they are not captures or proof of a
paid account's response. The original research-only snapshot changed no integration or UI. The #406 implementation preserves those review metrics and adds renewal independently. Automatic CI work is unchanged.

### Native OAuth transport limitation (October 5)

A public native OAuth client registered successfully with Greptile's advertised
registration endpoint. Authorization Code with S256 PKCE authenticated the
same user and organization: `GET https://api.greptile.com/v1/me` returned 200.
The same OAuth token returned 401 from the dashboard billing endpoint, and
`GET /api/auth/session` returned null. Identity/read authorization therefore
does not establish access to the private billing session. The diagnostic token
was revoked after these read-only checks.

Google's [native OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app)
requires an external browser rather than embedded WebKit. A complete native
billing login needs Greptile to authorize OAuth access to billing or provide an
authorized exchange into its dashboard session. The current temporary browser
flow fixes dashboard-cookie flicker, but does not resolve that provider-side
native authentication limitation.

## Google-backed billing login, October 29, 2026

Research for [#409](https://github.com/hemsoft-dev/codexbar-ios/issues/409),
following the deferred Google compatibility finding in
[PR #408](https://github.com/hemsoft-dev/codexbar-ios/pull/408#discussion_r4189900439).
Only first-party public documentation, anonymous public metadata and this app's
code were used. No provider account, browser session, credential export,
OAuth registration or authenticated endpoint probe was used for this recheck.

### Finding and exact missing capability

No provider-supported route from native Google sign-in to Greptile billing
could be established. Greptile needs to publish either:

1. A read-only billing API or MCP tool, with an OAuth grant that authorizes
   the selected user and organization and returns its actual billing period
   end. The scope, resource/audience, membership checks and renewal semantics
   must be specified. Identity access alone is insufficient.
2. An authorized dashboard-session exchange with native callback registration,
   bound to the initiating app attempt and verified user/organization. It must
   let the native app retain billing authorization securely without copying
   browser cookies or tokens.

The [OAuth authorization-server metadata](https://auth.greptile.com/.well-known/oauth-authorization-server)
advertises Authorization Code, refresh tokens, public-client authentication,
dynamic registration and S256 PKCE. Its scopes are `offline_access`, `offline`,
`openid` and `read`. The separate
[MCP resource metadata](https://api.greptile.com/.well-known/oauth-protected-resource/mcp)
advertises `read`, `write` and `offline_access` for `https://api.greptile.com/mcp`.
Neither describes billing permission or an exchange into dashboard authorization.
A broad `read` scope must not be assumed to grant billing access.

The current [MCP setup](https://www.greptile.com/docs/mcp/setup) documents browser
OAuth. Its [tools reference](https://www.greptile.com/docs/mcp/tools) describes
identity/organization discovery, repositories, reviews, context, knowledge bases
and analytics, without a billing/credit/subscription read. The
[CLI reference](https://www.greptile.com/docs/code-review/greptile-cli) likewise
does not specify billing access or native session transfer. The
[documentation index](https://www.greptile.com/docs/llms.txt) identifies no such
authorization contract. This is a bounded documentation finding, not a claim
that every credential or private deployment rejects billing.
The [public changelog](https://www.greptile.com/changelog) also establishes no
new native billing authorization route.

The anonymous [dashboard providers response](https://app.greptile.com/api/auth/providers)
still advertises Google and Greptile callbacks under
`https://app.greptile.com/api/auth/callback/`. These are dashboard server
callbacks, not native return or session-exchange contracts. The anonymous
[dashboard session](https://app.greptile.com/api/auth/session) is `null`, as
expected without authentication. That response alone proves no limitation on
an authenticated session. The earlier identity-200/billing-401 probe remains
historical evidence from October 5, not a new result from this investigation.

Google's [native-app OAuth policy](https://developers.google.com/identity/protocols/oauth2/native-app)
requires an external user agent and identifies embedded WebKit as a source of
`disallowed_useragent`. Apple's
[ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
returns a provider callback to the app. Replacing WebKit with that browser
does not itself supply billing authorization or transfer an HttpOnly dashboard
cookie. CodexBar therefore does not start a Google flow it cannot complete.

Today's [billing guide](https://www.greptile.com/docs/account/billing-seats)
describes prepaid, organization-shared credits and the human-facing Billing
dashboard. It supplies no billing API or native authorization contract. This
differs from the October 3/5 plan descriptions above, which are historical
records. New plan copy does not establish an account's allowance or renewal
date, and this change does not reinterpret stored results or invent a period.

### Reproduction and delivery boundary

At 8:10 PM EDT on October 29, fresh anonymous GETs to the six documentation
sources and four metadata/session sources above returned HTTP 200. The legacy
`mcp-v2` and `code-review-bot/billing-seats` documentation URLs redirect to the
current paths linked here. The Markdown sources are also available by appending
`.md` to documentation page paths. To repeat the metadata check without any
account or cookies:

```sh
curl --fail --silent --show-error \
  https://auth.greptile.com/.well-known/oauth-authorization-server
curl --fail --silent --show-error \
  https://api.greptile.com/.well-known/oauth-protected-resource/mcp
curl --fail --silent --show-error https://app.greptile.com/api/auth/providers
curl --fail --silent --show-error https://app.greptile.com/api/auth/session
```

The app-side fallback explains the limitation before sign-in, blocks Google
authorization in both normal and popup navigation, and offers return/cancel
without saving a credential. HTTP 403 now remains an authorization denial,
rather than being accepted as a transient billing failure during connection.
Saved sessions, account isolation, review history and compact renewal display
retain their existing behavior. Missing billing data stays unavailable;
previously observed dates stay last known after a failed refresh.

Local fixtures cover navigation blocking, cancellation, expiry, account
mismatch and billing rejection separately from identity success. The existing
manual iPhone/iPad reconnect journey also exercises fresh and saved attempts,
return to sign-in, popup rejection and cancellation back to account settings.
Its temporary HTML is isolated test content, not a provider page or proof of
working Google authorization. No test needs another machine or account.

A supported Google billing login and live renewal comparison remain pending
the provider contract. This docs/UI-honesty change does not claim to implement
them. No live account check is required from Franz for this delivery, and no
App Store action is part of it.
