# Antigravity usage contract

Source contract for the experimental Antigravity provider
([issue #601](https://github.com/hemsoft-dev/codexbar-ios/issues/601)). The
decision behind it is in
[docs/2026-11-23-antigravity-web-session-decision.md](docs/2026-11-23-antigravity-web-session-decision.md).
Terms used here are defined in [GLOSSARY.md](GLOSSARY.md).

Status on November 24, 2026: built against simulator fixtures. No signed-in
request has been made by an agent. The owner's live sign-in, the same-minute
comparison with Google's page and `agy /usage`, and the seven-day session check
are pending.

## What CodexBar does

1. The customer picks Antigravity in Add Account and reads a notice. Nothing
   loads from Google before they accept it.
2. An in-app browser opens Google's Antigravity web app at
   `https://antigravity.google.com/remote/settings?settingsScreen=Models`. The
   customer signs in to Google there.
3. Google's page requests the account's quota from Google's service. CodexBar
   reads the text of that response as the page receives it.
4. Once a response parses into one or more of the four meters, CodexBar saves
   the account. A canceled or failed sign-in leaves no account and no website
   data.
5. On refresh, CodexBar loads the same page in a hidden web view that uses the
   account's website data, and reads the response again.

CodexBar sends no request of its own to a Google host for this provider. It
computes no Google signature, sends no Google API key, and neither copies
cookies into its own storage nor writes them to the Keychain. The only thing it
tells the web view to do is open a page.

## What is read

A script injected into the main frame of `antigravity.google.com` forwards the
response text of two of the page's own calls. It reads no cookies, headers or
request bodies, and it starts no request.

| Page call | Host | Used for |
| --- | --- | --- |
| `…/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserQuotaSummary` | `aicode.clients6.google.com` or `aicode.googleapis.com` | The meters |
| `…/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserProfile` | same | The plan name. The email in this response is discarded. |

CodexBar accepts a forwarded response only when it came from the main frame of
`https://antigravity.google.com`, the call's host and method match the table,
the status is 2xx and the body is at most 256 KB.

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
- A pool with a full fraction and no reset time is untouched: 0% used.
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
| The page asked for Google sign-in | "Google asked you to sign in again", no values, a sign-in action |
| The page loaded but reported no usage | An explanation that an account which only works through a connected computer can't be read, no values |
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
  A sweep at launch deletes any store no saved account names.
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
`quota-response.json` in the app container: page hosts and paths, outcomes and
the last quota response. They hold no profile response, cookie, header or
account name. Release builds write nothing.

## Known limits

- Google can block sign-in inside an in-app browser, or change the page, at any
  time. Either stops the provider.
- The response layout is inferred from public page code, and the unit-test
  fixtures are built from it. A sanitized live response replaces them after the
  owner's first sign-in.
- Whether the Models & Usage screen fetches quota when opened by its address in
  a hidden web view is unverified. Sign-in records the page path that reported
  usage, and refresh tries it first.
- Passkey and security-key sign-in may not work inside an in-app browser.
- AI credits and Gemini app chat limits are out of scope.
