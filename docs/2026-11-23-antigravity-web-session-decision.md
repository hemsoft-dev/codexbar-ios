# Antigravity from Google's Models & Usage page

Decision record for [issue #601](https://github.com/hemsoft-dev/codexbar-ios/issues/601).
Decided by Franz on November 23, 2026. Written November 24, 2026.

## Decision

CodexBar iOS shows Antigravity quota by loading Google's own Models & Usage
page in an in-app browser and reading the quota response that page fetched. The
provider is labelled Experimental and shows a notice before sign-in. The source
contract is in [ANTIGRAVITY-USAGE.md](../ANTIGRAVITY-USAGE.md).

| Topic | Decision |
| --- | --- |
| Scope | Antigravity only. Gemini app chat limits stay out. |
| Meters | Gemini Models weekly and five-hour, Claude and GPT Models weekly and five-hour. Extra pools appear only when Google reports them. |
| Display | Percent used in whole numbers, like every other card. |
| Sign-in | Guided on the phone in an in-app browser. No computer, helper program or hosted service. |
| Read mechanism | Google's real page loads and CodexBar reads what that page fetched. CodexBar forges no request and stores no Google session keys in the Keychain. |
| Customer notice | Labelled Experimental, with a short plain notice before sign-in. |
| Request to Google for permission | Only if Apple asks for authorization. |

## What this reverses

On November 9, 2026 Franz removed Google Gemini and Antigravity from iOS
([#556](https://github.com/hemsoft-dev/codexbar-ios/issues/556),
[research](https://github.com/hemsoft-dev/codexbar-ios/issues/519#issuecomment-6753965016)).
The Gemini source was removed for relying on a private Google web interface.
The Antigravity source was removed because correct numbers needed Antigravity's
own OAuth client and user agent.

This decision reverses the first reason for Antigravity only: CodexBar again
depends on a private Google web interface. It does not reverse the second.
CodexBar still never signs in as Antigravity's client, never calls Google's
internal Cloud Code service and never presents itself as another program.

[MUSE-CODE.md](../MUSE-CODE.md) rules out reading a provider's web dashboard
for Muse Code. That ruling stands for Muse Code. This record is an exception
for Antigravity, made by the owner with the risks below accepted.

## Why

Gemini 4 Neon became Antigravity's default model for Google AI Pro and Ultra on
November 18, 2026, and CodexBar iOS showed those customers nothing. No
documented quota API exists. Checked and empty on November 23: Google's API
directory, the OAuth scope list, Cloud Quotas, Service Usage, Cloud Monitoring,
the Antigravity SDK, hooks, headless mode and Google One. A
[forum request](https://discuss.ai.google.dev/t/feature-request-official-read-only-quota-api-for-third-party-apps/188769)
for a read-only quota API from October 13, 2026 has no Google reply.

The Models & Usage page is the only source found that works from the phone
alone. Franz opened it in Safari on his iPhone on November 23 with no computer
involved and saw his plan and all four meters.

## Rejected alternatives

| Alternative | Why it was rejected |
| --- | --- |
| Sign in on the phone with CodexBar's own Google OAuth client | Google's service returned HTTP 403 or placeholder values for it. |
| Sign in as Antigravity's client, as some desktop tools do | Breaches Google's terms on client identity and puts the customer's Google account at risk. The Council was unanimous against it. |
| Desktop relay: a computer reads `agy /usage` and sends it to the phone | Needs a helper program and a hosted relay, and the phone can't refresh its own data. Franz dropped it. |
| Wait for Google to publish an API or grant permission | Weeks or months with no sign of an answer. Franz chose to ask only if Apple requires it. |
| Leave Antigravity unsupported | Was the recommendation until the page was found. |

## Risks Franz accepted

- The [Antigravity terms](https://antigravity.google/terms) and
  [FAQ](https://antigravity.google/docs/faq) treat third-party software that
  accesses the service as a breach that can end in account suspension. Google
  has never exempted read-only viewers. No ban tied to one was found.
- Apple guideline 5.2.2 lets App Review ask for the service's authorization.
  None exists.
- Google may block sign-in inside an in-app browser, and the page can change
  without notice.

## Council

Seats: Gemini 4 Neon, Claude Opus 5.5, GPT 6.2 Sol. Missing: none. Two rounds on
November 23, 2026.

- Round one was unanimous against signing in as Antigravity's own client and
  for a new provider identifier.
- In round two GPT 6.2 Sol found the Models & Usage page.
- Dissent: Claude Opus 5.5 and GPT 6.2 Sol both advised that reading the page
  into CodexBar needs Google's permission. Claude Opus 5.5 also warned that
  Google may block in-app sign-in. Franz chose to proceed, so the dissent is
  recorded here and not resolved.

## Feasibility gate and order of work

The issue says to build nothing else until a development build on Franz's
phone passes the gate. The implementation in the first pull request was built
before the gate ran. The agent recorded why on November 24: the gate needs
Franz's own Google sign-in and seven elapsed days, the repository's rules say
live provider checks are not an agent prerequisite, and the gate build and the
product share the same sign-in and reading code. The gate items stay open on
the issue. If any of them fails, the pull request is reverted.

Gate status on November 24, 2026: Franz signed in on his iPhone and reported
that the values match Google's page, which covers items 1 and 2 by his report.
The response the build recorded matches the inferred layout. Item 3 is pending,
and so is a working refresh after sign-in: the first one Franz tried, at 21:20
UTC, reported no usage, because the hidden page was given 15 seconds and needs
longer. The reader now waits up to 45 seconds; that is not yet confirmed on his
phone.

Gate items:

1. Google sign-in completes inside the in-app browser and reaches the Models &
   Usage page.
2. The app reads the four meters, their reset times and the plan from the
   page's own response, and the values equal what the page displays.
3. The sign-in survives seven days of normal refreshes without asking again.

## Stop conditions

Stop and report on the issue if any of these happens:

- Google blocks in-app sign-in, or the page changes so that the read breaks
  repeatedly.
- A ban is credibly tied to this kind of reading.
- Apple asks for authorization that can't be shown.
