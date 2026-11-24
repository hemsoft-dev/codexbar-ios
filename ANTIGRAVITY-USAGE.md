# Antigravity usage contract

Source contract for the experimental Antigravity provider
([issue #601](https://github.com/hemsoft-dev/codexbar-ios/issues/601)). The
decision behind it is in
[docs/2026-11-23-antigravity-web-session-decision.md](docs/2026-11-23-antigravity-web-session-decision.md).
Terms used here are defined in [GLOSSARY.md](GLOSSARY.md).

Status on November 24, 2026: the owner signed in on his iPhone at 19:26 UTC with
a development build and reported that the card's values match Google's page.
The response that build recorded is now a unit-test fixture, and it has the
layout described below. No signed-in request has been made by an agent.

A refresh after sign-in did not work on that build, and now does. At 21:20 UTC
the owner refreshed and the card said Google's page didn't report usage. The
build's log and a picture of the hidden page showed why: Google's app uses its
phone layout on a page 768 points wide or less, where Settings opens as a list
and the usage screen never opens from its address, so the page never asked for
quota. The hidden page is now 1280 points wide. With that build the owner's
phone read quota 3 seconds after opening the page at 21:46 UTC and 1 second
after at 23:18 UTC, on the same sign-in, and he confirmed the four meters.

Still pending with the owner: a sign-in on the build where sign-in also reads
through the wide page, the comparison with `agy /usage`, and the seven-day
session check.

Checked signed out on November 24, 2026, against Google's live page: the hidden
read reports "sign in again" in under a second, and in the iOS simulator the
in-app browser reaches Google's "Sign in" form after the notice. Nobody entered
credentials, so whether Google accepts a sign-in there is still unverified.

## What CodexBar does

1. The customer picks Antigravity in Add Account and reads a notice. Nothing
   loads from Google before they accept it.
2. An in-app browser opens Google's Antigravity web app at
   `https://antigravity.google.com/remote/settings?settingsScreen=Models`.
   Signed out, that page stays on its own address and shows Google's Sign in
   link. The browser follows that link once, as a tap would, and the customer
   signs in on Google's form. When Google sends them back, the browser reopens
   the usage screen.
3. Google's page requests the account's quota from Google's service. CodexBar
   reads the text of that response as the page receives it.
4. Once the customer is signed in, CodexBar opens the same usage screen in a
   hidden page 1280 points wide and reads the quota response from it. On a
   phone-width page Google's app shows Settings as a list, and the usage screen
   that asks for quota opens only when tapped.
5. Once a response parses into one or more of the four meters, CodexBar saves
   the account. A canceled or failed sign-in leaves no account and no website
   data.
6. On refresh, CodexBar loads the usage screen in the same kind of wide hidden
   page, using the account's website data, and reads the response again.

CodexBar sends no request of its own to a Google host for this provider. It
computes no Google signature, sends no Google API key, and neither copies
cookies into its own storage nor writes them to the Keychain. The only thing it
tells the web view to do is open a page.

## What is read

A script that runs only in the main frame of `antigravity.google.com`, and does
nothing on Google's sign-in pages, forwards the
response text of two of the page's own calls, and the address of the Sign in
link in Google's account bar when the page shows one. It reads no cookies,
headers or request bodies, and it starts no request.

| Page call | Host | Used for |
| --- | --- | --- |
| `…/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserQuotaSummary` | `aicode.clients6.google.com` or `aicode.googleapis.com` | The meters |
| `…/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserProfile` | same | The plan name. The email in this response is discarded. |

CodexBar accepts a forwarded response only when it came from the main frame of
`https://antigravity.google.com`, the call's host and method match the table,
the status is 2xx and the body is at most 256 KB. It accepts a Sign in link
only when it is `https://accounts.google.com/ServiceLogin`. During sign-in that
link is the one address the browser opens that the customer didn't tap. During
a refresh it means the saved sign-in has ended, and nothing is opened.

The page asks for `application/json+protobuf`, where each message is a JSON
array indexed by field number. The field numbers below were read from the
page's public script on November 23 and 24, 2026. They are not documented by
Google and can change without notice.

| Message | Fields |
| --- | --- |
| Quota response | 1: summary, which holds 1: response |
| Response | 1: buckets, 2: groups, 3: description |
| Group | 1: buckets, 2: display name, 3: description |
| Bucket | 1: bucket ID, 2: display name, 3: window, 4: remaining fraction, 5: remaining amount, 6: reset time (1: seconds, 2: nanoseconds), 7: description, 8: disabled |
| Profile response | 1: email, 2: plan (1: ID, 2: display name) |

## How a response becomes a card

| Google's bucket ID | Metric | Identifier |
| --- | --- | --- |
| `gemini-weekly` | Gemini Models weekly | `antigravityWeb.gemini-weekly` |
| `gemini-5h` | Gemini Models five-hour | `antigravityWeb.gemini-5h` |
| `3p-weekly` | Claude and GPT Models weekly | `antigravityWeb.3p-weekly` |
| `3p-5h` | Claude and GPT Models five-hour | `antigravityWeb.3p-5h` |

- Percent used is 100 minus the whole percent Google's page shows. The page
  shows `Math.round(fraction × 100)`, so 0.9725 remaining is 97% on the page
  and 3% used on the card.
- A pool with a full fraction is untouched: 0% used. Google sends a reset time
  for it anyway, and its page shows none. The card shows a reset time only for a
  pool Google describes as used, or whose fraction is below full.
- A five-hour pool Google marks disabled shows "Weekly limit reached". It is
  never shown as 0% or 100%.
- A pool that is missing, has no fraction, has a fraction outside 0 to 1, has a
  window that contradicts its ID, or appears twice shows "Unavailable".
- Any other bucket with a readable fraction is an extra pool. It gets its own
  metric named with Google's group and row names and the identifier
  `antigravityWeb.extra-<bucket ID>`. It never replaces one of the four.
- A reset time in the past is not shown.
- No pace forecast is shown. Google reports when a limit refreshes, not when
  its window began.
- The plan pill shows the plan name from the profile response. Without one
  there is no pill.

## States

| What happened | What the card shows |
| --- | --- |
| The page reported usage | The meters, read time, and plan when reported |
| The page showed Google's Sign in link, or moved to Google's sign-in form | "Google asked you to sign in again", no values, a sign-in action |
| The page loaded signed in but reported no usage in time | The last reading, marked stale, with an explanation that also says an account which only works through a connected computer can't be read. Without an earlier reading, the explanation and no values. |
| CodexBar wasn't on screen | The last reading, marked stale. Nothing is loaded, and the next refresh on screen runs at once. |
| The page didn't load | The last reading, marked stale, with the failure. Stale readings raise no alerts and add no history. |
| The response wasn't recognized | The last reading, marked stale, and a note that an app update may be needed |

Google's web app has two modes. In Remote Conversations it asks Google's
service for quota directly, which is what CodexBar reads. In Remote Control it
asks the customer's desktop app through a tunnel, and CodexBar does not read
that path.

## Storage and isolation

- Each sign-in gets a new `WKWebsiteDataStore` with a random identifier. Two
  accounts never share a store, and no other feature uses identified stores.
- The Keychain item for an account holds the store's identifier and the page
  path that reported usage. It holds no Google cookie, token or key.
- Removing the account, signing out or replacing the sign-in deletes the store.
  WebKit refuses to delete a store whose web view closed within the last
  second, so the deletion is tried again two seconds later, and a sweep at
  launch deletes any store no saved account names.
- One account loads Google's page at most once every five minutes. A page that
  failed to load can be retried after one minute. Sign-in hands its reading to
  the first refresh, so adding an account loads the page once.

## Coexistence with the retired Google providers

Version 2.0 had Gemini and Antigravity providers that
[#556](https://github.com/hemsoft-dev/codexbar-ios/issues/556) removed. Their
cleanup still runs at every launch and deletes anything saved under the
provider identifiers `gemini` and `antigravity`. The new provider's identifier
is `antigravityWeb`. No dotted part of any identifier it creates equals a
retired identifier, and a test pins that. Website data from the retired Gemini
sign-in is removed from the shared store once per installation.

## Development-build diagnostics

Debug builds write `Library/Caches/AntigravityGate/events.log` and
`quota-response.json` in the app container: page hosts and paths, timings,
outcomes and the last quota response. When a hidden page reports no usage they
also record its route, its headings and button labels, and a picture of the
page as `hidden-page.png`. The picture can show the signed-in account's name
and avatar, and it stays in the app's caches on the device. They hold no
profile response, cookie or header. Release builds write nothing.

## Known limits

- Google can block sign-in inside an in-app browser, or change the page, at any
  time. Either stops the provider.
- The response layout was inferred from public page code and matched the one
  live response captured so far. Most unit-test fixtures are still built from
  that layout; one is the live response.
- The hidden page has to stay wider than Google's phone layout. If Google
  changes that width, or how the usage screen opens, refresh stops reporting
  usage and the card keeps the last reading, marked stale.
- The reader waits up to 30 seconds on the first page and 15 on each fallback.
  On the owner's phone quota arrived 1 to 3 seconds after the page opened.
- Google's app reports its own address as the entry (`/remote`) even on the
  usage screen, so refresh opens that entry's usage screen first.
- Refresh runs only while CodexBar is on screen. In the background iOS suspends
  the app mid-load, so widgets and the watch show the last reading with its
  time until the app is opened.
- Passkey and security-key sign-in may not work inside an in-app browser.
- AI credits and Gemini app chat limits are out of scope.
