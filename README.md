# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard with account-scoped usage cards for Codex, GitHub Copilot,
  GitHub Billing, Claude, Grok, X Subscription, Cursor, OpenRouter, OpenCode
  Go + Zen, Moonshot (Kimi), Greptile, and Google Gemini
- Live provider adapters and settings for enabling accounts, choosing supported
  authentication methods, labeling accounts, and storing credentials in Keychain
- Usage history and charts, configurable usage alerts, and home-screen and
  lock-screen widgets
- Read-only Greptile review-activity tracking through an organization API key,
  with completed reviews kept distinct from pull requests and billing credits.
  The [Greptile allowance investigation](GREPTILE-USAGE.md) explains why its
  published review tools do not establish an account's remaining credits
- One Google Gemini account with five-hour and weekly choices for Gemini Apps,
  Gemini Models, and Other models, plus a separate Argon weekly choice. Missing
  provider quotas stay unavailable
- An embedded watchOS companion with a live, read-only dashboard that mirrors
  presentation-ready account metrics, visualization choices, ordering, and
  freshness from iPhone; provider setup, credentials, and provider networking
  remain iPhone-only
- Demo data limited to previews, smoke and isolated UI tests, widget galleries, and screenshots
- Simulator unit tests spanning configuration and authentication, provider
  parsing and networking, dashboard and settings, widgets, history, and alerts,
  plus watchOS foundation tests and a SwiftPM smoke harness; see
  [Build and Test](AGENTS.md#build-and-test) and the isolated iPhone/iPad
  [account UI journeys](UI-TESTING.md)
- A measured Release [usage-history performance budget](USAGE-HISTORY-PERFORMANCE.md)
  with retained-data limits and manual workflow runs

## Requirements

- Xcode 26 or later for App Store submissions
- iOS 17 or later
- watchOS 10 or later for the companion app

## Release preparation

Version 1.4.0 build 4 is the current App Store release. Apple approved it after
the October 7, 2026 submission, and it has been live since October 8, 2026. Its
shipping source is tagged [`v1.4.0`](https://github.com/hemsoft-dev/codexbar-ios/tree/v1.4.0).
See the [App Store tracker](APP-STORE.md) and
[1.4.0 preparation record](release-assets/1.4.0/README.md) for the source
boundary, release copy, validation and submission identifiers. The next release
is 2.0.0.

## Local validation

For a local readiness audit, run
`./.agents/skills/perfection/scripts/run-perfection.sh`. Its seven gates cover
pinned repository-wide SwiftLint, complete strict concurrency, iOS build and
unit tests, SwiftPM smoke tests, and watchOS build and unit tests. Use `--list`
for gate names or `--status` for the most recent historical summary. See the
[perfection skill](.agents/skills/perfection/SKILL.md) for focused runs and the
separate manual UI and function-risk release checks. Security analysis and the
performance budget run manually for relevant changes and release preparation;
see [security analysis](SECURITY-ANALYSIS.md) and
[performance verification](USAGE-HISTORY-PERFORMANCE.md).

The [CI policy](CI-POLICY.md) records measured runtimes and the lightweight
required PR lint/configuration gate. All five quality checks and both UI families
run before a release or on demand. It also records manual security/performance
dispatch and failure ownership. Manual analysis keeps its existing failure rules
and artifacts.

## OpenCode sign-in

OpenCode Go and Zen use system-browser approval with workspace selection.
Choose browser sign-in to allow an existing browser login, or private sign-in
to start a separate session. Google may still require identity verification.
No credential JSON or workspace-ID entry is required. See
[OpenCode sign-in](OPENCODE-SIGN-IN.md) for reconnection, local validation, and
pending live-provider checks.

## ChatGPT / Codex sign-in

Choose **Settings → Accounts & Groups → Add Account → ChatGPT / Codex** to add
another Codex account. Choose browser sign-in to use the device's usual browser
session, or private sign-in to start a separate session. If Google does not
recognize the private session, try browser sign-in; Google may still require
identity verification. Select the intended ChatGPT account, since an existing
browser login may select the first account automatically. CodexBar keeps each
credential and usage result separate and checks the returned identity before
connecting a second entry. If ChatGPT returns an identity already connected,
neither saved account changes. If identity cannot be verified, sign in again
on the existing account and retry; CodexBar does not assume an unknown
identity is different. A legacy single account remains usable without
reauthentication.

The Codex card shows the ChatGPT plan reported by OpenAI, including separate
Pro, Pro (More) and Pro (Max) names. See [Codex subscription names](CODEX-PLANS.md)
for verified mappings and numeric-name limits.

**Credits pool** is off by default. To show the reported remaining credits,
open **Settings → Accounts & Groups → your Codex account → Metrics** and turn
it on, or show it in Customize Card. Choices stay separate for each account
and survive relaunch and missing data. Counts are credits, not dollars;
missing data stays unavailable and explicit unlimited status is labeled.
See [Codex credits](CODEX-CREDITS.md) for the read-only source and limitations.

## Grok sign-in

Grok consumer usage uses guided approval in a system browser. Choose the Grok
identity to monitor, approve the device request, and return to CodexBar. The
app verifies the identity and reads the shared usage period before securely
saving the account's token. A verified weekly paid pool and the remaining Extra
Usage Credits balance appear as separate values when supplied. A verified plan
name suggests the account label without replacing your edits. When the CLI omits
all usage fields for a verified paid plan's active shared weekly period, the
card shows 0% with "No included usage reported by Grok." An explicit null or
conflicting usage remains unavailable. API spending and Cursor's Grok Bot
allowance are not Grok subscription meters. If the CLI does not verify a
consumer allowance, the card says it is unavailable. Disconnect
removes only this device's saved credential. The Grok Build CLI client and
credits endpoint are first-party CLI contracts, not a published third-party
API; see [the provider contract](GROK-CONSUMER-CONTRACT.md). Live sign-in and
quota comparison are pending with the account owner.

## X Subscription sign-in

An X Subscription account uses the same guided xAI approval as Grok: one
browser sign-in, no Cursor sign-in and no pasted tokens. The card shows the
shared weekly pool once, with its exact reset, plus Extra Usage Credits as a
separate balance. When xAI reports a per-product split, it appears as detail
rows under "Weekly pool by product", never as extra meters or a second pool. A
recognized unified plan name (Plus, Premium, Super or Ultra) sets the plan
pill; any other tier, including a SuperGrok name, leaves the pill unavailable
without hiding the pool. Missing or malformed values stay unavailable. Existing
Grok and Cursor accounts keep their metrics; when they report a unified plan,
their cards point to the X Subscription account and nothing is moved or
deleted. Third-party model spending in Cursor is not reported separately. See
[the X Subscription contract](X-SUBSCRIPTION-CONTRACT.md). The live comparison
with grok.com on a unified account is pending with the account owner.

## GitHub Copilot Sign-In

CodexBar bundles the public OAuth client ID and client secret used by
Copilot CLI-compatible clients. Static credentials shipped in an app cannot be
kept confidential: these values identify the OAuth application, but they do not
provide access to a GitHub account. Browser sign-in still requires the user to
authorize access, uses PKCE to protect the authorization-code exchange, and
stores the resulting account tokens in the iOS Keychain.

Developers can replace the bundled values in debug builds with the
`CODEXBAR_COPILOT_OAUTH_CLIENT_ID` and
`CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET` environment variables. Release builds
ignore process-environment overrides and use values from the app bundle or the
documented defaults in `CopilotWebAuthService.swift`.

## GitHub Billing

GitHub Billing is a separate provider from GitHub Copilot. Choose
**Add Account → GitHub Billing → Sign in with GitHub**, review the requested
permissions, and select either your personal account or an organization where
you have billing access. Each monitored owner gets its own configuration and
Keychain credential; the integration never reads or replaces a Copilot token.

Personal Free and Pro cards show monthly allowance progress from GitHub's
[included-product table](https://docs.github.com/en/billing/reference/product-usage-included)
for eligible Actions minutes, Actions storage, Packages storage and data transfer,
Git LFS storage and bandwidth, and Codespaces compute and storage. Organization
Free and Team cards show the same account-scoped metrics except personal
Codespaces allowances. CodexBar requires GitHub's returned billing month to
contain the refresh time. Each verified metric states used, included, and
remaining usage, shows zero usage as 0%, and preserves overage above 100%.
Enterprise allowances stay unavailable because GitHub pools them above the
organization scope. The per-repository Actions cache allowance is not presented
as an account-wide bar.

Actions progress includes private-repository standard GitHub-hosted runners.
CodexBar normalizes each runner's usage to GitHub's Linux allowance-minute rate,
matching the Included usage figure in GitHub Billing. Returned unit prices must
match GitHub's current
[runner pricing table](https://docs.github.com/en/billing/reference/actions-runner-pricing)
before those minutes are accepted. Known paid larger runners from GitHub's
[SKU catalog](https://docs.github.com/en/billing/reference/product-and-sku-names#github-actions),
self-hosted runners, and public repositories are excluded from the hosted
standard-runner allowance. Standard-runner unit prices must match the current
pricing table exactly. Missing summary rows, hidden repository classifications,
unknown units, and unknown SKUs make only the affected metric unavailable. A
problem with one metric does not suppress
other verified allowances. Codespaces compute converts returned machine hours
with the documented core count in each `codespaces_compute_d*` SKU. Actions
storage converts GitHub's accrued GB-hours to the monthly GB figure shown in
GitHub Billing and includes only usage tied to repositories verified as private.
GitHub Billing does not identify
package visibility or whether transfer came from a free Actions download, so a
nonzero Packages storage or transfer quantity keeps that allowance unavailable;
a verified zero quantity can still show 0%. Each allowance also requires
returned gross, discounted, and billable quantities to be complete and
internally consistent. Evidence fails closed if GitHub reports billable covered
usage before the verified included allowance is exhausted.

Cards also show gross charges, discounts, net spend, and month-end projections.
Aggregate amounts use a complete, consistent ISO currency returned by GitHub;
when GitHub supplies no currency evidence, CodexBar uses GitHub's documented USD
billing currency. Partial, conflicting, or invalid currency evidence suppresses
monetary values instead of relabeling them. Metered usage groups into one
summary per product (Copilot, Actions, Codespaces, Packages, Git LFS, and any
other products GitHub returns) with consumed, discounted, and billable amounts
and quantities. Unit prices keep GitHub's source precision, for example
$0.006/minute, instead of rounding into a different rate.

Routine qualifications, including the lack of personal budgets and calculation
notes, live in the More Information sheet. Actionable problems such as
permission failures, incomplete billing data, and repositories that could not
be classified stay on the card. Organization cards keep allowance progress,
usage by product and SKU, monetary totals and projections, and returned
organization or repository budgets visibly separate. Other budget scopes remain
visible as unavailable because organization usage cannot establish their
consumption safely. Unsupported plans, missing API fields, unavailable billing
endpoints, permission failures, and rate limits remain visible instead of being
guessed.

The browser flow requests `repo admin:org user`, uses PKCE with a loopback
callback, and stores only the returned account token. Personal billing endpoints
require `user`, not the profile-only `read:user`, while GitHub requires
`admin:org` to include organization plan details. Existing users who authorized
the earlier scope must sign in again and approve the expanded permission.
The `user` scope also permits profile changes, reading private email addresses,
and following or unfollowing users. `admin:org` permits organization and team
changes. CodexBar never uses those additional capabilities. Classic GitHub OAuth
does not offer a private-repository metadata-only scope: `repo` permits
repository changes, while CodexBar limits its use to reading repository
visibility for billing classification. It limits `admin:org` to reading the
organization plan. GitHub supports separate
tokens per user, OAuth application, and scope combination, so the billing flow's
distinct scope combination and Keychain entry do not broaden or replace a saved
Copilot token even when both flows use the bundled public OAuth registration.
Billing administrators must grant access to organization billing data. Debug
builds can override the registration with
`CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_ID` and
`CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_SECRET`; release builds use the bundled
registration. Live account comparison remains an owner verification step.
Developers can run the synthetic API contract suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run GitHubBillingFixtureTests
```

## Google Gemini sign-in

One Gemini account contains seven Google usage choices, including Argon weekly. Gemini Apps uses a
Google website session; Gemini Models and Other models use a separate
coding OAuth session inside the same account. Both connections are experimental.
See the verification boundaries in [Gemini sign-in evidence](GEMINI-SIGN-IN.md)
and [coding session setup](ANTIGRAVITY-SETUP.md).

Choose **Add Account → Google Gemini → Sign in with Google** and sign in to the
Google account you want to track. Each attempt opens a private website window
without reusing Safari or another CodexBar account's session. After sign-in,
CodexBar returns from Google Account to Gemini Usage automatically, verifies
both the five-hour and weekly meters with reset times, and saves the session
in that account's iOS Keychain entry. You can also use the window's **Back** and
**Gemini Usage** controls.

Use **Sign in Again with Google** to renew an expired session. Existing accounts
created by pasting credentials keep their saved session, label, group, history,
and display preferences. If a coding session is linked, confirm that the new
Google account selected in the browser belongs to the linked coding session
before the new session is saved. Add a
separate Gemini entry for another Google account. **Disconnect Gemini Apps**
removes this account's website session and preserves its coding session.
**Disconnect Coding Session** removes only coding authorization. Neither action
signs you out of Google in Safari or disconnects another CodexBar entry.

Open **Coding Usage → Connect Coding Usage** in the same Gemini settings.
Confirm that you will choose the same Google account, then complete browser
authorization. This flow requires the developer to configure a Google OAuth
iOS client before deployment; end users do not enter client settings. Existing standalone coding accounts are retained and
can be linked here after that confirmation; CodexBar does not guess associations
from matching labels. All seven choices stay available in Metrics and Customize
Card even when a source needs setup. Their saved identities, layout, and history
survive the account consolidation. See [coding session setup](ANTIGRAVITY-SETUP.md)
for developer configuration and renewal details.

Cancellation, a failed usage check, and a failed Keychain save leave the existing
credential unchanged. If Google denies access, cancel and retry with an eligible
account. If the sign-in page cannot load, check your connection and retry.

The integration uses ordinary Google website sign-in in a nonpersistent
`WKWebView` with its default user agent. It does not use a Google OAuth grant,
copy another application's OAuth registration, export Safari cookies, or require
a desktop CLI. Only secure `.google.com` root-path `__Secure-1PSID` and optional
`__Secure-1PSIDTS` cookies are retained. The app does not inspect page contents,
password fields, or JavaScript. Other website data exists only in the temporary
browser store and is discarded when that window closes.

Google session credentials are sensitive and may grant broader account access.
CodexBar uses the retained values only for read-only requests to
`gemini.google.com`, rejects cross-origin usage redirects, and never includes
them in diagnostics, settings, widgets, or Watch snapshots. This depends on an
undocumented consumer web contract. If Google changes or blocks it, sign-in or
refresh will report failure. See [Gemini sign-in evidence](GEMINI-SIGN-IN.md) for
the desktop reference, platform mechanism, and sanitized feasibility results.

## Open Locally

```bash
open CodexBarIOS.xcodeproj
```

The project includes shared `CodexBarWatch` and `CodexBarWatchTests` schemes.
The watch source is isolated under `CodexBarWatch/`; it intentionally does not
compile the iOS authentication, notification, widget, or UIKit-dependent code.
Use the documented simulator commands in
[Build and Test](AGENTS.md#build-and-test) to build and test the watch targets.

## Mutation Testing

A focused, non-blocking mutation-testing pilot covers deterministic dashboard
sorting and App Review prompt policy logic. See
[MUTATION-TESTING.md](MUTATION-TESTING.md) for the pinned tool, baseline
findings, survivor triage, and reproducible local command.

## Reference Repo

The current Windows app is a C# / WPF / .NET 9 system tray app with shared provider logic in `src/CodexBar.Core`. The iOS implementation should port behavior from there deliberately instead of sharing project structure directly.

## Gemini coding quotas

The Gemini account's Coding Usage connection reads Gemini Models and Other
models, Claude/GPT, from the internal Antigravity quota adapter. Each has
five-hour and weekly metrics alongside Gemini Apps on one dashboard card. Argon
has a separate weekly choice. The native summary may omit Gemini Models or Argon;
those pools stay unavailable, as tracked in [#519](https://github.com/hemsoft-dev/codexbar-ios/issues/519).
See
[coding session setup](ANTIGRAVITY-SETUP.md) for browser setup, renewal, and the
remaining live comparison checks.

### Provider card plan pills

Grok uses a separate verified tier pill and generated Grok account names, preserving
custom account names and verified tier metadata through reusable refresh failures.
X Subscription follows the same rules with its unified plan names.

Every account card shows its verified plan or product type in the header,
including when collapsed. Codex `pro` and `prolite` identify the Pro family;
Claude's returned Max tier distinguishes 5x and 20x. Existing verified
Copilot, GitHub Billing, Grok and Greptile plan metadata is reused. A verified
Greptile Free billing state can also identify Free without a renewal date.
OpenRouter and Moonshot identify API credits. Other missing or unrecognized
plans show "Plan unavailable". Google usage sources currently provide no verified
subscription identity; neither a Google account name nor quota size establishes
Google AI Pro or Ultra. The fallback pill is presentation only and is not saved
as detected subscription metadata in widgets, watch snapshots or history.

The current [ChatGPT Pro tiers](https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers)
include Pro 100, 200 and 500. Legacy `pro`/`prolite` metadata does not identify
one of those numeric tiers, so the pill displays Pro without guessing a price
or usage multiplier.

### Claude saved usage resets

Eligible Claude accounts can view provider-returned saved usage resets, their
expiry and the windows they restore. Using a reset requires a separate account
confirmation. CodexBar refreshes usage after every result and protects an
unconfirmed request against another consumption, including after relaunch.
Unavailable reset details never appear as a zero balance.

### Weekly Sub Utilization Score

The iPhone and iPad dashboard and metric details show SUS beside each weekly
quota. Green starts at 90, yellow at 75, and red is below 75. A score of 100
means the current pace reaches the quota at reset. Underuse lowers the score;
an early lockout lowers it by the share of the week spent without quota.
Five-hour windows have no score. Missing quota, missing window times, expired
windows, and windows under 12 hours old show `n/a`.

Fleet SUS averages each account's scored weekly pools, then weights each account
once by its monthly reference price. The editable table is in
`SubscriptionUtilizationFleet.referenceMonthlyPrices`: Claude $200, Codex $200,
and the unified Google Gemini/Antigravity subscription $19.99. A reported Codex
`pro` plan uses $200 and `prolite` uses $100 immediately; no billing date is
assumed. If any scored account's price is unknown, all accounts receive equal
weight. Missing and stale pools do not contribute a score.

The formula and rounding match the Chief's
[pinned reference](https://github.com/hemsoft-dev/chief/blob/61d50412cbad1d653b3bda8a4ae2a68a6d38419e/scripts/usage.py).
Only reported Grok and X Subscription percentages produce bars. Omitted usage
stays unavailable even for a verified paid plan.
