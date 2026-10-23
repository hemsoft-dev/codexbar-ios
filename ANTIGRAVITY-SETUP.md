# Gemini coding connection

One Google Gemini account contains seven usage choices in CodexBar. Its
Gemini Apps connection uses Google website cookies. Its Coding Usage connection
uses an OAuth session to read Gemini Models and Other models,
Claude/GPT. The two credential formats are separate and are never substituted
for each other. Antigravity is an internal quota adapter, not a separate account
choice or dashboard card.

This experimental coding integration uses CodexBar's registered Google OAuth
iOS client for native browser authorization. It uses an unofficial Google usage
API.
Franz's live comparisons remain follow-up verification for
[#319](https://github.com/HemSoft/codexbar-ios/issues/319) and do not block agent
implementation or merge.

## Seven metric choices in one Gemini card

| Source | Metric label | Preserved identity |
| --- | --- | --- |
| Gemini Apps | Gemini Apps five-hour | `gemini.five-hour` |
| Gemini Apps | Gemini Apps weekly | `gemini.weekly` |
| Coding session | Gemini Models five-hour | `antigravity.gemini-5h` |
| Coding session | Gemini Models weekly | `antigravity.gemini-weekly` |
| Coding session | Argon weekly | `antigravity.gemini-argon-wtu-weekly` |
| Coding session | Other models five-hour | `antigravity.3p-5h` |
| Coding session | Other models weekly | `antigravity.3p-weekly` |

All seven choices appear together in Gemini's Metrics settings and Customize
Card. Hide, order, width, and visualization preferences survive refresh and
relaunch. Missing connections show Setup required without invented percentages
or resets. Missing or disabled quotas retain their actual status. History,
widgets, and Watch preserve source identities and contain only observed values.

The current native quota summary may omit Gemini Models and Argon. Their
choices then show unavailable quota and SUS `n/a`. The app does not run or
import CLI data. A supported native retrieval source is tracked in
[#519](https://github.com/hemsoft-dev/codexbar-ios/issues/519).

Existing standalone coding accounts remain stored until you link them from
Gemini settings. Confirm that both sessions belong to the same Google account.
Matching labels do not prove identity, and CodexBar does not guess an association.
Confirmed linking transfers coding credentials and metric preferences into the
chosen Gemini account and preserves its observed history. Unlinked records stay
retained internally. Old source setup cards disappear; saved choices are retained
when their Gemini account can be identified.

## Browser setup

In Gemini settings, choose **Connect Coding Usage** and complete Google's
browser authorization. If Gemini Apps is connected, confirm the selected
Google account after the browser returns and before the session is saved. CodexBar saves the returned session in account-scoped
Keychain storage and refreshes usage. Cancellation preserves saved credentials.
The app no longer asks users to paste or export session JSON.

### Developer configuration

The Google Auth Platform project named `CodexBar` is published for external
accounts. Its iOS client is registered for bundle ID `com.hemsoft.CodexBarIOS`,
App Store ID `6787769891`, and Apple team ID `W2A23PX5BP`. The app target's
Debug and Release configurations set `GOOGLE_CODING_CLIENT_ID` to that public
client ID. It is an application
identifier, not a client secret.

The application derives the reverse-client-ID callback scheme and uses
`:/oauthredirect`, PKCE S256, a system browser session, and offline access.
End users never enter OAuth configuration. If the registration changes, update
both app-target build configurations. A missing or invalid setting makes the
connection action report that coding sign-in is not configured in that build.

The requested scopes are `cloud-platform` and `userinfo.email`, following the
[desktop reference](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md).
The iOS flow uses a public native client without a client secret. Legacy saved
credentials retain their existing renewal behavior; new native credentials
persist their public-client renewal mode. HTTP redirects from the token endpoint
are rejected, and raw token errors are never shown in the UI.

Google's [native app documentation](https://developers.google.com/identity/protocols/oauth2/native-app)
is the callback and client-registration reference. An identity grant does not
establish quota availability. Franz owns live account and quota verification;
this remains pending and is not an implementation prerequisite.

## Quota contract

The verified request is an authenticated JSON `POST` with body `{}` to:

```text
https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
```

The response contains `groups[].buckets[]`. The parser uses bucket IDs and
windows, not translated display names or model lists:

| Bucket | Window | CodexBar metric |
| --- | --- | --- |
| `gemini-5h` | `5h` | Gemini Models five-hour |
| `gemini-weekly` | `weekly` | Gemini Models weekly |
| `3p-5h` | `5h` | Other models five-hour |
| `3p-weekly` | `weekly` | Other models weekly |

Percent used is `100 * (1 - remainingFraction)`. Thus `0` remaining is 100%
used and `0.69` remaining is 31% used. Reset timestamps come only from supplied
`resetTime` fields. Missing, disabled, duplicate, out-of-range, or expired
buckets stay unavailable. Partial responses retain only proven current metrics
and identify the missing ones. A wholly unavailable response follows the app's
existing failure and stale-data presentation.

There is deliberately no fallback to `cloudcode-pa.googleapis.com`. A live
request on September 5 returned four all-full buckets there, while the CLI's
daily backend returned Gemini weekly `0.7202861` remaining, or 27.97139% used.
Supplying a project ID did not correct the other backend. The daily response
matched the CLI-local fractions and active Gemini weekly reset. Untouched
bucket resets advanced with request time and still need hands-on comparison.
See the [sanitized investigation receipt](https://github.com/HemSoft/codexbar-ios/issues/314#issuecomment-5555218152).

Requests reject redirects, disable automatic cookies and caching, and never
include raw server errors in user-facing messages. Quotas go only to the daily
backend; renewal credentials go only to `oauth2.googleapis.com/token`.

## Live verification follow-up for issue #319

The September 5, 2026 baseline inspection found CodexBar 1.3 build 3 on the
connected iPhone 17 Pro Max running iOS 27.0, build 24A5418b. Its saved account
configuration included Google Gemini and no Antigravity account. Gemini Apps
showed 0% five-hour and 1% weekly usage on both the phone and the desktop Usage
limits page. The displayed resets were 11:44 p.m. EDT and September 8 at
7:44 p.m. EDT, respectively. The installed app's source commit is unknown.

On September 6, the PR app was installed and launched on the same phone.
Mirroring verified all four coding visibility switches and their persistence.
The two live Gemini Apps values still matched the consumer reference; their
visibility, order, width and visualization changes survived relaunch and the
original layout was restored. No Antigravity credential has been imported.

Franz took ownership of the remaining live iPhone testing on September 6 and
directed that it no longer block PR #320. He reported Gemini Models weekly at
71% remaining and the other three coding buckets at 100% remaining. These are
reference values, not a successful phone fetch. Coding values and reset parity,
reconnection and combined-card customization remain his follow-up checks in
[#319](https://github.com/HemSoft/codexbar-ios/issues/319). They are not claimed
as passed and do not block delivery of the unified account.

Franz can use these optional checks after receiving the updated build:

1. Unlock the phone and use a signed-in CLI session for the same Google account.
   Record `agy --version`, interactive `/usage`, and
   `agy -p "/usage" --output-format json`. Do not publish identity or tokens.
2. After the agent delivers the configured build using `DEVICE-DEPLOYMENT.md`,
   complete Connect Coding Usage in Gemini settings.
3. Refresh both sources in the same comparison interval. Record used versus
   remaining semantics, values and supplied resets for the six existing metrics and Argon when reported.
4. Toggle and customize each choice, relaunch, then hide or disconnect Apps
   and verify all four coding metrics remain in the same Gemini card. Keep before/after screenshots locally
   and publish only evidence without identity or credentials.
5. Record renewal if matching client fields are available, or exercise and
   document browser reconnection. Saving a credential without a successful quota refresh
   does not prove access.

Connect Coding Usage now implements native browser authorization and the tracked
build configuration supplies the registered Google iOS client ID. Before phone
delivery, the agent must complete automated validation. Franz's live checks then
verify account selection and the coding quotas returned by that grant; desktop
success alone does not establish access from the iPhone.
