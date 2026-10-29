# CodexBar Privacy Policy

Effective date: October 18, 2026

CodexBar Usage Monitor is a local dashboard for monitoring AI provider usage, limits, and API balances. It does not require a CodexBar account and does not send your provider credentials or usage data to HemSoft servers.

## Data CodexBar Stores On Your Device

CodexBar may store the following information locally on your iPhone, iPad, or
paired Apple Watch:

- Provider account labels and configuration choices you enter in the app.
- API keys, access tokens, refresh tokens, and similar credentials for providers you choose to connect.
- Usage, balance, refresh status, and snapshot history used to show cards, trends, alerts, and widgets.
- GitHub Status monitoring choices and local observation state, including the
  selected check interval, banner and notification preferences, last status
  snapshot and check or error result used to show freshness, dismissed-banner
  identity, consecutive-failure retry state, and the pending local-notification
  queue used to avoid duplicates.
- Widget configuration, including which tiles you choose to show.
- Purchase access and timing records, including the applicable Pro plan,
  purchase and verification dates, access deadlines, local clock information,
  and records of expiration, revocation or unresolved purchase verification.
- Widget and Apple Watch access-validity and update-ordering state.
- An Apple Watch snapshot containing local account and metric identifiers,
  account labels, metric names and values, visualization choices, reset context,
  status and freshness, alongside its access-validity state.

Provider credentials are stored using the iOS Keychain where appropriate. Widget snapshots and app settings are stored locally in the app container or app group container so the app and widgets can display your configured tiles.

The iPhone app sends the latest dashboard presentation, access-validity and
update-ordering snapshot to the paired Apple Watch through Apple's Watch
Connectivity framework. Provider credentials, credential identifiers, cookies,
raw provider responses, and provider networking never move to the watch. The watch stores its last valid
snapshot locally so it can remain useful during a temporary disconnection
while Pro access is valid. A Pro lock hides usage; it does not delete the saved
provider snapshot.

## Third-Party Provider Requests

When you connect a provider, CodexBar uses the credentials you provide to request usage, balance, or review-activity data for the configured account or organization directly from that provider. Depending on what you configure, this may include services such as OpenAI/ChatGPT, Anthropic Claude, GitHub Copilot, Grok, X Subscription, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot AI (Kimi), Greptile, and Google Gemini.

Those requests are made to the provider's own APIs or web endpoints. The provider may process the request according to its own terms and privacy policy.

For Grok, CodexBar starts xAI's device authorization in a system browser and
stores the resulting account-scoped OAuth token in the iOS Keychain after
verifying identity and consumer usage access. The app sends the bearer token
only to `auth.x.ai` for identity and renewal and to
`cli-chat-proxy.grok.com` for read-only consumer credits. The token may grant
broader xAI API access, but CodexBar does not send inference requests, buy
credits, or link subscriptions. It does not read grok.com browser cookies or
send credentials to Cursor. Widgets and the Watch receive usage snapshots,
never tokens. Disconnect removes the local token, not xAI's grant.

X Subscription accounts use the same xAI device authorization and token
handling as Grok. Each account's token is stored separately in the iOS
Keychain and sent only to `auth.x.ai` and `cli-chat-proxy.grok.com` for
read-only usage, credits and plan name. CodexBar does not sign in to Cursor
for this account or read billing pages.

For Google Gemini, CodexBar opens Google's website in a new nonpersistent
browser store for each sign-in attempt. You enter your password on Google's
page; CodexBar does not inspect the page, password fields, or JavaScript.
It reads only secure `.google.com` root-path `__Secure-1PSID` and optional
`__Secure-1PSIDTS` cookies. After verifying consumer usage, it stores those
session values in the selected account's iOS Keychain entry. Other browser data
is discarded when the sign-in window closes. Existing manually connected
accounts can use the same browser flow to renew their session.

These session values may grant broader Google account access. CodexBar sends
its retained values only to `gemini.google.com` for read-only consumer Gemini
Apps usage requests. They are never written to app settings, logs, diagnostics,
widgets, or Watch snapshots. Disconnecting one Gemini entry removes its saved
credential without affecting other entries or your Safari session.

For Greptile billing renewal, CodexBar opens a temporary nonpersistent browser
session and retains only the secure, root-path Auth.js session cookie (or its
numbered chunks) for `app.greptile.com`. After verifying the user and selected
organization, it saves those session values, the verified user identifier, and
the selected organization in that account's own iOS Keychain entry. Other
browser data is discarded when the sign-in session closes. Fresh Google-backed
billing sign-in or reconnection may be unavailable in this version.

The retained dashboard session can grant broader Greptile account access.
CodexBar sends it only to `app.greptile.com` for identity verification and
read-only billing-state requests. The identity response's Greptile token is
used for read-only review-activity requests to `api.greptile.com/mcp`, scoped to
the selected organization. Existing organization API-key accounts use that MCP
endpoint directly. The app does not trigger reviews, spend credits, buy plans,
or change billing settings. The dashboard transport bypasses shared cookie
storage and HTTP caches and rejects redirects. Session cookies and tokens are
never included in History, widgets, Watch snapshots, or feedback diagnostics.
Disconnect removes the local saved credential; it does not sign out another
CodexBar account or the user's browser session. Removing the account also
removes its saved local usage history.

GitHub Status monitoring is independently configurable and off by default. If
you enable it, CodexBar periodically requests GitHub's public
[`summary.json`](https://www.githubstatus.com/api/v2/summary.json) Statuspage
endpoint directly from your device. iOS may also perform a deferred background
check when the system permits it.

The GitHub Status request does not use or send a GitHub account, token, provider
account identifier, credential, or usage or balance history. GitHub processes
the request under its own
[Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

For GitHub Copilot browser sign-in, CodexBar includes public OAuth application
credentials that identify the Copilot-compatible client. They are not personal
credentials and do not grant access to a GitHub account. You must authorize the
sign-in with GitHub, the authorization-code exchange is protected with PKCE,
and the account tokens returned for your session are stored in the iOS
Keychain.

GitHub Billing is authorized and stored separately from GitHub Copilot. It asks
GitHub for `repo`, `admin:org`, and `user` OAuth scopes so it can read the
selected user's plan and billing usage, discover organizations they administer,
read organization plan details, and classify billed repository usage as public
or private. GitHub's `repo` scope permits repository changes. The `admin:org`
scope also permits organization and team changes; CodexBar uses it only to read
organization plan details. The `user` scope required by personal billing also
permits profile changes, reading private email addresses, and following or
unfollowing users through its included `user:email` and `user:follow` scopes.
CodexBar does not request email addresses or change profiles, follows,
repositories, organizations, or teams. Its data requests are read-only.
CodexBar sends the token only to GitHub's API and OAuth token endpoints. Billing
amounts, repository names returned with usage, organization names, and derived
allowance or budget readings may be stored locally in dashboard history,
widgets, and Watch presentation snapshots. Each GitHub Billing account's
access and optional refresh tokens remain in that account's own iOS Keychain
entry and are removed when that account is disconnected.

## Purchases

Apple processes CodexBar Pro purchases and payments through your App Store
account. CodexBar does not receive your payment card details. CodexBar uses StoreKit on
your device to check purchase status, renewals, expiration, refunds and access
for people who bought the original paid app. It does not send purchase
information to a HemSoft server or require a CodexBar account.

CodexBar keeps purchase access and timing records locally, including the
applicable Pro plan, purchase and verification dates, access deadlines, local
clock information, and records needed to preserve expiration, revocation or
unresolved verification decisions. Its local purchase cache does not contain
Apple Account identifiers, transaction identifiers or payment details. Widgets and the paired Apple Watch receive
access-validity information and provider presentation data, including account
labels, local account and metric identifiers, and usage values. Provider
credentials remain separate from purchase checks and are not included in those
snapshots.

CodexBar has no billing backend, advertising or third-party analytics SDK.
Apple processes purchases under its own
[privacy policy](https://www.apple.com/legal/privacy/). When you choose Restore
Purchases, CodexBar asks Apple to synchronize purchases available to your
current App Store account.

## Data HemSoft Collects

HemSoft does not operate a backend service for CodexBar and does not collect your provider credentials, API keys, account balances, usage limits, widget configuration, or snapshot history.

CodexBar does not include third-party analytics, advertising, or crash-reporting SDKs in the current release.

When you explicitly choose **Report a Problem**, CodexBar first previews a
diagnostic built from a fixed list of non-secret categories: app version/build,
operating-system version, general device category, affected surface, provider
name when relevant, and optional booleans or categories for authentication
method, configured/secret-present state, normalized failure or HTTP status,
refresh/freshness, Widget freshness, or Apple Watch connection/freshness. You
can remove all optional technical details, copy the preview, cancel, open a
private email draft, or explicitly open GitHub. If a safely prefilled GitHub URL
would be too long, CodexBar copies the preview instead of opening it.

CodexBar does not read or add provider credentials, account labels, your email
address, account or device identifiers, balances, usage history, raw errors
or provider responses, widget selections, or Apple Watch snapshots to the
diagnostic, email draft, or GitHub link. It also does not add credentials,
tokens, cookies, logs, screenshots, or attachments. **Suggest an Improvement**
prefills a structured editable message plus general app and device details.

Private feedback drafts are addressed to `fphemmer@gmail.com` and use a subject
beginning `[CodexBar Feedback]`. CodexBar shows the recipient, subject, and
message as copyable fields before offering to open an external email composer.
Opening the composer does not send the message; you review and explicitly send
it. Before leaving CodexBar, the app warns that your configured email app may
display and use its currently selected sending account. Your email app and
provider process a draft you open, and Gmail processes a message you send to
the recipient mailbox.

CodexBar opens email through a standard `mailto:` URL. iOS hands that URL to an
external handler and does not give CodexBar control over that app's
system-managed sender interface. Apple's in-app mail composer likewise exposes
configuration for recipients, subject, body, attachments, and preferred sending
address, but no supported control for hiding the sender row. CodexBar therefore
does not read, store, log, or prefill the selected sender address, and its
`mailto:` URL contains only the recipient path plus `subject` and `body` query
fields. See Apple's documentation for
[`UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:))
and
[`MFMailComposeViewController`](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller).

GitHub reports remain public and require a GitHub account. No issue is submitted
to GitHub until you explicitly submit the public form; opening a prefilled form
transfers its query parameters to GitHub. HemSoft may convert emailed feedback
into a de-identified public GitHub issue, but will not publish the sender's
email address, name, personal details, or other identifying content as part of
that conversion.

## Sharing And Sale Of Data

HemSoft does not sell your data and does not share your CodexBar data with advertisers or data brokers.

## Data Retention And Deletion

CodexBar keeps local provider settings, credentials, and snapshots until you
remove a provider, use an available in-app removal or reset control, or delete
the app. Purchase and access records are separate from provider accounts.
Removing a provider or losing Pro does not clear those purchase records or
cancel an Apple subscription. The app updates local purchase records as Apple
provides new evidence; it has no separate purchase-history erase control.
Deleting the app removes app data stored in the app container. Some Keychain
items may remain according to iOS Keychain behavior; you can remove saved
provider credentials from CodexBar settings before deleting the app.

Turning off GitHub Status monitoring clears the current status snapshot,
dismissed-banner identity, and pending local-notification queue. The selected
monitoring settings, last attempt and check times, last check error, and
consecutive-failure count remain stored locally until a later check overwrites
them or you delete the app. CodexBar does not currently provide a separate
control to erase that retained check metadata.

## Contact

For support or privacy questions, use the support information in [SUPPORT.md](SUPPORT.md).

## Gemini coding authorization

Google coding access tokens, optional refresh tokens, and OAuth client
fields stay in the selected account's Keychain entry. Quota requests send the
access token only to `cloudcode-pa.googleapis.com`, or to
`daily-cloudcode-pa.googleapis.com` when the first is unavailable. If supplied, renewal
credentials go only to `oauth2.googleapis.com/token`. These credentials may
grant broader Google account access and are never included in History, widgets,
or Watch snapshots. Coding sign-in opens Google in a system authentication
session, which may reuse your existing browser login. The app exchanges the
returned authorization code using PKCE. The configured native OAuth client
requests cloud-platform and email scopes; it does not embed a client secret.
Previously imported sessions remain stored until you reconnect or disconnect.
