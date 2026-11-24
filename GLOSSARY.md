# Glossary

Terms the app, its documents and its issues use with one meaning. Add a term
here when a conversation settles what it means.

## Antigravity

| Term | Meaning |
| --- | --- |
| Antigravity | Google's agentic coding product, and the name of the CodexBar provider that shows its subscription quota. In code the provider is `antigravityWeb`. It is not the Antigravity provider that version 2.0 had and [#556](https://github.com/hemsoft-dev/codexbar-ios/issues/556) removed; that one is called the retired Antigravity provider. |
| Models & Usage page | The screen in Google's Antigravity web app at `antigravity.google.com` that shows the plan and the quota pools. It is CodexBar's only source for Antigravity. |
| Gemini Models | The quota group for Google's own models. Google's page uses this name. |
| Claude and GPT Models | The quota group for Anthropic, OpenAI and other third-party models. Google's page writes "Claude and GPT models"; its bucket IDs start with `3p`. |
| Weekly limit | A group's seven-day pool. Google labels it "Weekly Limit Remaining". |
| Five-hour limit | A group's five-hour pool. Google labels it "Five Hour Limit Remaining". Google disables it when the group's weekly limit is used up. |
| The four meters | Gemini Models weekly, Gemini Models five-hour, Claude and GPT Models weekly, Claude and GPT Models five-hour. |
| Extra pool | Any pool Google reports besides the four meters. It is shown as its own metric and never replaces one of the four. |
| Percent used | What every CodexBar card shows: a whole number, 100 minus the remaining percent Google's page shows. Google's page and CLI show percent remaining. |
| Reading | One successful read of the Models & Usage page for one account, with the time it was read. |
| Stale reading | The last reading, shown after a later read failed. It raises no alerts and adds no history. |
| Experimental | A provider whose source the service doesn't officially offer to third-party apps. Add Account labels it and shows a notice before sign-in. |
| Gemini app limits | Chat limits of the Gemini app at `gemini.google.com`. They are different pools from Antigravity's and are not supported. |
