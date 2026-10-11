# Changelog

Notable changes to CodexBar are documented here. Entries describe shipped app
behavior; development-only changes are listed separately when they affect
building, testing, or releasing the app.

## 1.5.0 - Unreleased

### Added

- See verified OpenCode Go and Go Plus renewal countdowns, with the exact billing
  date in card details. Canceled plans show when access ends; payment recovery
  and subscriptions belonging to another workspace member never show an assumed
  renewal. The existing Dashboard setting controls the countdown.
  ([#451](https://github.com/hemsoft-dev/codexbar-ios/issues/451))

- Connect billing for Claude and Grok to see verified subscription renewal dates
  beside their usage. Billing sign-in checks the same account, canceled plans show
  their access end date in details, and the existing setting controls all renewal
  pills. Providers without verified billing dates explain what is missing.
  ([#446](https://github.com/hemsoft-dev/codexbar-ios/issues/446))

- See compact subscription renewal countdowns when the connected provider supplies
  a verified billing date, with exact dates in card details. Control their display
  in Dashboard settings; usage reset dates remain separate. Billing dates that the
  current connection cannot provide stay unavailable.
  ([#444](https://github.com/hemsoft-dev/codexbar-ios/issues/444))

- See actual Greptile free-credit usage, included credits and remaining allowance
  alongside the renewal date for connected dashboard accounts. Credit usage stays
  separate from completed reviews; missing billing values remain unavailable.
  ([#429](https://github.com/hemsoft-dev/codexbar-ios/issues/429))

- View saved Claude usage resets, the windows they restore and their expiry.
  Confirm the account before using one, then see refreshed usage and the remaining
  resets. Availability updates when a grant starts or expires, and provider cooldowns
  show when a reset can next be used. Unconfirmed requests stay protected against another consumption.
  ([#420](https://github.com/HemSoft/codexbar-ios/issues/420))

### Changed

- Show only the green number beneath Codex's Credits pool heading, removing the
  repeated "credits" suffix from dashboard tiles and customization previews.
  ([#449](https://github.com/hemsoft-dev/codexbar-ios/issues/449))

- Hide redundant OpenCode plan pills and show named Google AI subscriptions when
  the connected Google account reports them, including verified plan variants.
  Missing subscription metadata stays unavailable instead of guessing from quotas.
  ([#442](https://github.com/hemsoft-dev/codexbar-ios/issues/442))

- Read Codex Credits pool balances as whole credits, with locale-aware grouping
  and consistent rounding across cards, widgets and Apple Watch.
  ([#437](https://github.com/hemsoft-dev/codexbar-ios/issues/437))

- Recognize Codex subscriptions by their ChatGPT Pro 100, Pro 200 or Pro 500
  names, with ChatGPT 20 for Plus and ChatGPT Free for Free. Plan labels stay
  tied to the signed-in account when credentials change or a refresh fails.
  ([#433](https://github.com/hemsoft-dev/codexbar-ios/issues/433),
  [#435](https://github.com/hemsoft-dev/codexbar-ios/issues/435))

- Identify each provider card with a subscription or billing-type pill, including
  Codex plan families and Claude Max 5x/20x. Accounts whose provider does not report
  a verified plan show “Plan unavailable” instead of a guessed tier.
  Grok keeps its verified tier after a temporary usage or tier-lookup failure, and generated
  Grok account names no longer repeat the plan pill. An unsupported account
  clears its former Grok tier and quota. Custom names are preserved.
  ([#417](https://github.com/HemSoft/codexbar-ios/issues/417))

### Fixed
- Claude renewal dates accept the provider's timestamp or legacy date fields without requiring both. Billing details now explain expired sign-in, account mismatch, denied access and unavailable responses, with a shortcut to billing settings. ([#454](https://github.com/hemsoft-dev/codexbar-ios/issues/454))

- See verified Cursor Pro and Pro+ subscriptions in each account’s header pill, with independent plan names that survive refresh and relaunch. Unknown plans remain clearly unavailable. ([#438](https://github.com/hemsoft-dev/codexbar-ios/issues/438))

- Resolve Claude subscription names from connected-account profile metadata,
  including Max 5x and 20x, when sign-in metadata is missing or stale. Supported
  plan changes appear on a later refresh without signing out; unknown plans
  stay unavailable and profile failures preserve valid usage.
  ([#431](https://github.com/hemsoft-dev/codexbar-ios/issues/431))

- Open feedback and support links in the organization GitHub repository.
  ([#427](https://github.com/hemsoft-dev/codexbar-ios/issues/427))

- Keep Claude Fable 5 and 5.1 under one weekly metric, separate from shared
  Claude allowances. Saved visibility, layout, history, widget and Apple Watch
  choices survive model-name changes. A saved Fable widget stays unavailable
  when Claude omits its allowance. Tile width menus identify the saved selection
  for accessibility tools.
  ([#421](https://github.com/hemsoft-dev/codexbar-ios/issues/421))

### Developer Experience

- Document verified subscription billing contracts and access gaps for Cursor,
  Google AI, personal Copilot, OpenCode Go and paid Greptile. Add a manual,
  offline OpenCode contract replay and a separate implementation follow-up.
  ([#447](https://github.com/hemsoft-dev/codexbar-ios/issues/447))

- Run ordinary PR lint and configuration checks without native build/test reruns.
  Extensive iOS/watchOS tests, function-risk checks, strict-concurrency builds,
  smoke validation and both UI families run before releases or on demand.
  Duplicate post-merge validation is removed. Manual UI checks scroll card headers
  clear of the navigation bar before interacting with them, use the Settings
  sidebar's own scroll surface, and reveal saved-credential controls before checking them.
  ([#419](https://github.com/hemsoft-dev/codexbar-ios/issues/419))

- Use connected Codex as the sole required AI reviewer. Repository guidance
  preserves current-head review, addressed-thread resolution, and required CI
  and human approvals without waiting for optional review products.
  ([#405](https://github.com/HemSoft/codexbar-ios/issues/405))

## 1.4.0 - 2026-10-07

More provider metrics, guided sign-in, and up to 90 days of usage history.

### Added

- Connect experimental Google Gemini and see Gemini Apps, Gemini Models, and Other models in one
  account, with separate five-hour and weekly limits, reset countdowns, and usage
  projections when the provider supplies enough data. Choose an account through guided
  Google sign-in and return automatically to CodexBar.
  ([#296](https://github.com/HemSoft/codexbar-ios/issues/296)) ([#314](https://github.com/HemSoft/codexbar-ios/issues/314)) ([#299](https://github.com/HemSoft/codexbar-ios/issues/299)) ([#319](https://github.com/HemSoft/codexbar-ios/issues/319)) ([#330](https://github.com/HemSoft/codexbar-ios/issues/330)) ([#332](https://github.com/HemSoft/codexbar-ios/issues/332))

- Connect Grok to track verified paid weekly usage and Extra Usage Credits when
  available. Its consumer subscription stays separate from Cursor's Grok Bot allowance
  and developer API spending.
  ([#355](https://github.com/HemSoft/codexbar-ios/issues/355)) ([#361](https://github.com/HemSoft/codexbar-ios/issues/361))

- Connect GitHub Billing separately from Copilot to see personal and organization
  spending, included allowances, budgets, discounts, and month-end projections where
  supported. Permission disclosures explain billing access before sign-in.
  ([#336](https://github.com/HemSoft/codexbar-ios/issues/336)) ([#349](https://github.com/HemSoft/codexbar-ios/issues/349))

- Track separate Cursor Models, Other Models, and Grok Bot usage. Each metric has its
  own saved visibility on the dashboard, widgets, and Apple Watch.
  ([#292](https://github.com/HemSoft/codexbar-ios/issues/292)) ([#286](https://github.com/HemSoft/codexbar-ios/issues/286))

- Track every usage window reported for each Codex account, including separate Codex
  Spark limits. Optionally show the reported Codex Credits balance in credits, with a
  separate saved choice for each account.
  ([#270](https://github.com/HemSoft/codexbar-ios/issues/270)) ([#391](https://github.com/HemSoft/codexbar-ios/issues/391))

- Explore up to 90 days of daily usage history alongside recent detailed samples. Choose
  today, three days, seven days, one month, or three months.
  ([#290](https://github.com/HemSoft/codexbar-ios/issues/290))

- Show or hide individual metrics from account Settings or Customize Card using the same
  saved preferences.
  ([#272](https://github.com/HemSoft/codexbar-ios/issues/272))

- See Greptile's provider-returned free-allowance renewal countdown and local date on
  the dashboard and in More Information. Missing dates stay unavailable; failed
  refreshes mark the last known date as stale. Fresh Google-backed billing sign-in or
  reconnection may be unavailable in this release; saved verified sessions can still
  return renewal dates.
  ([#406](https://github.com/HemSoft/codexbar-ios/issues/406))

### Changed

- Connect OpenCode Go and Zen through browser approval and workspace selection. Choose
  an existing browser session or private sign-in without pasting cookies, JSON, or
  workspace IDs. Reconnection preserves your saved card choices and History, and
  verifies the same account and workspace before saving a session.
  ([#353](https://github.com/HemSoft/codexbar-ios/issues/353)) ([#356](https://github.com/HemSoft/codexbar-ios/issues/356))

- Choose normal-browser or private sign-in for ChatGPT / Codex. Distinct accounts retain
  separate usage and credentials, and duplicate identities remain blocked. Google may
  still require identity verification.
  ([#368](https://github.com/HemSoft/codexbar-ios/issues/368))

- Read Claude's shared windows as "5-hour" and "Weekly", and Codex's long window as
  "30-day", while retaining saved metric layouts and values.
  ([#384](https://github.com/HemSoft/codexbar-ios/issues/384)) ([#393](https://github.com/HemSoft/codexbar-ios/issues/393))

- See GitHub Billing usage, included or discounted amounts, and billable spending
  grouped by product. Routine qualifications appear in More Information; permission
  failures and incomplete billing evidence remain visible on the card. Unsupported
  allowances stay unavailable rather than showing a guessed percentage.
  ([#347](https://github.com/HemSoft/codexbar-ios/issues/347))

- See Cursor's minimum 1% display for small positive model usage while History and
  forecasts retain the measured values. Independent Grok Bot failures no longer erase
  model usage or its saved metric choice.
  ([#400](https://github.com/HemSoft/codexbar-ios/issues/400))

- Distinguish Grok's narrowly inferred zero from provider-reported weekly usage. Missing
  or conflicting evidence stays unavailable, and weekly subscription usage remains
  separate from credit balances.
  ([#363](https://github.com/HemSoft/codexbar-ios/issues/363)) ([#388](https://github.com/HemSoft/codexbar-ios/issues/388))

- Read clearer privacy disclosures for GitHub Billing permissions and account-specific
  Greptile session credentials. These explanations do not add permissions or change data
  handling.
  ([#371](https://github.com/HemSoft/codexbar-ios/issues/371)) ([#373](https://github.com/HemSoft/codexbar-ios/issues/373))

### Fixed

- Keep Cursor usage current by renewing sign-in automatically when possible. Guided
  reconnection preserves saved card choices; failed refreshes retain visibly stale
  measurements instead of replacing them with fresh zeros. Valid zero usage and a Bot-only failure do not request reconnection.
  ([#402](https://github.com/HemSoft/codexbar-ios/issues/402))

- Keep Cursor on-demand spending visible when no remaining allowance is returned,
  including amounts above the spending cap. Preserve over-100% readings, partial
  results, and saved choices across dashboard, widgets, Watch, alerts, and History.
  Accounts with no Grok Bot allowance no longer show a misleading Bot meter.
  ([#388](https://github.com/HemSoft/codexbar-ios/issues/388)) ([#294](https://github.com/HemSoft/codexbar-ios/issues/294)) ([#288](https://github.com/HemSoft/codexbar-ios/issues/288))

- Keep History dates readable at chart edges on iPhone and iPad, including larger text
  sizes. Successful refreshes update the latest value without creating extra samples
  inside the configured sampling interval.
  ([#386](https://github.com/HemSoft/codexbar-ios/issues/386)) ([#274](https://github.com/HemSoft/codexbar-ios/issues/274))

- Make account menus easier to open at accessibility text sizes on iPad, remove excess
  space above account headings, and show the selected visualization after customization
  and relaunch.
  ([#381](https://github.com/HemSoft/codexbar-ios/issues/381)) ([#398](https://github.com/HemSoft/codexbar-ios/issues/398)) ([#346](https://github.com/HemSoft/codexbar-ios/issues/346))

- Recover safely from duplicate saved account or History identifiers instead of crashing
  or discarding account data and credentials before an explicit reset or replacement.
  ([#277](https://github.com/HemSoft/codexbar-ios/issues/277)) ([#276](https://github.com/HemSoft/codexbar-ios/issues/276))

- Keep Settings Done visible through nested screens, preserve Back navigation and
  pending-edit validation, and make provider rows selectable across their full width
  with one clear VoiceOver action. Account group selection now exposes a separate
  accessibility value.
  ([#265](https://github.com/HemSoft/codexbar-ios/issues/265)) ([#280](https://github.com/HemSoft/codexbar-ios/issues/280)) ([#307](https://github.com/HemSoft/codexbar-ios/issues/307))

- Keep Gemini's six metric choices and independent layouts through missing quota data,
  failed refreshes, and reconnect cancellation. Require confirmation before linking the
  same Google identity, retain usable saved sessions, and offer Sign In Again when
  authorization expires. Disabled quotas stop publishing to alerts and companion
  displays while existing History stays saved.
  ([#319](https://github.com/HemSoft/codexbar-ios/issues/319)) ([#299](https://github.com/HemSoft/codexbar-ios/issues/299)) ([#301](https://github.com/HemSoft/codexbar-ios/issues/301)) ([#303](https://github.com/HemSoft/codexbar-ios/issues/303))

- Handle OpenCode browser dismissal and authorization already in progress without
  discarding an approved sign-in. Return to the app for verification, offer a fresh
  attempt when checks stall, and keep Cancel available.
  ([#358](https://github.com/HemSoft/codexbar-ios/issues/358))

- Keep GitHub Billing Actions minutes and storage together, including eligible macOS
  runner usage. Request the permission required for personal billing and explain
  rejected or incomplete reads without exposing account data. Reconnecting to a
  different owner clears that card's previous usage and History instead of mixing
  accounts.
  ([#351](https://github.com/HemSoft/codexbar-ios/issues/351)) ([#344](https://github.com/HemSoft/codexbar-ios/issues/344)) ([#336](https://github.com/HemSoft/codexbar-ios/issues/336))

- Keep Grok weekly usage above Extra Usage Credits for accounts using the default order,
  while preserving deliberate card reordering. Recognize provider-reported empty credit
  balances as zero and clear prior usage and History when a Grok connection is removed.
  ([#365](https://github.com/HemSoft/codexbar-ios/issues/365)) ([#388](https://github.com/HemSoft/codexbar-ios/issues/388)) ([#355](https://github.com/HemSoft/codexbar-ios/issues/355))

- Keep Greptile's last complete review results when pagination or refresh fails. Show
  returned allowances and reset dates without inferring a free plan or treating missing
  quota as zero. API-key saves explain validation failures, and More Information opens
  in-app account settings for reconnection. Organization accounts remain separate.
  ([#284](https://github.com/HemSoft/codexbar-ios/issues/284)) ([#281](https://github.com/HemSoft/codexbar-ios/issues/281)) ([#395](https://github.com/HemSoft/codexbar-ios/issues/395)) ([#406](https://github.com/HemSoft/codexbar-ios/issues/406))

### Developer Experience

- Kept full iPhone/iPad UI validation as a manually dispatched release gate, requiring
  all 28 journeys on each independent device-family worker. Stronger Settings dismissal
  and menu/customizer checks reject background controls as proof of a completed action.
  Fixed-date billing fixtures remain valid across calendar changes.
  ([#373](https://github.com/HemSoft/codexbar-ios/issues/373)) ([#307](https://github.com/HemSoft/codexbar-ios/issues/307))

- Kept automatic CI workload bounded to the existing lint, concurrency, unit/risk and
  smoke gates. New costly validation stays local or manual unless completed before-and-after measurements prove no increase in elapsed or billed runner time.
  ([#337](https://github.com/HemSoft/codexbar-ios/issues/337)) ([#339](https://github.com/HemSoft/codexbar-ios/issues/339)) ([#341](https://github.com/HemSoft/codexbar-ios/issues/341))

- Added per-function iOS and Watch coverage/risk reports and local regressions for
  Gemini session decisions, Greptile pagination, dashboard tile selection, and Settings
  routing/notification decisions without changing their customer behavior.
  ([#306](https://github.com/HemSoft/codexbar-ios/issues/306)) ([#374](https://github.com/HemSoft/codexbar-ios/issues/374)) ([#375](https://github.com/HemSoft/codexbar-ios/issues/375)) ([#376](https://github.com/HemSoft/codexbar-ios/issues/376)) ([#377](https://github.com/HemSoft/codexbar-ios/issues/377))

- Added complete-source Swift security analysis and a reviewed findings baseline through
  manual workflow runs. Added replayable Release performance comparisons for History
  recording, chart generation, serialized size, and retained growth, with machine
  diagnostics and failure evidence preserved.
  ([#309](https://github.com/HemSoft/codexbar-ios/issues/309)) ([#310](https://github.com/HemSoft/codexbar-ios/issues/310)) ([#325](https://github.com/HemSoft/codexbar-ios/issues/325)) ([#336](https://github.com/HemSoft/codexbar-ios/issues/336))

- Expanded the seven-gate local perfection audit with pinned repository-wide SwiftLint
  and complete strict-concurrency validation. Kept separate UI, risk, security, and
  performance checks outside its score.
  ([#311](https://github.com/HemSoft/codexbar-ios/issues/311))

- Prepared privacy-safe native storefront capture scenes for Gemini, Grok, GitHub
  Billing, History and the Watch companion, with isolated outputs and opaque PNGs.
  Reconciled release copy against the last live version and documented the deferred
  Greptile Google-backed billing-login limitation.
  ([#373](https://github.com/HemSoft/codexbar-ios/issues/373)) ([#371](https://github.com/HemSoft/codexbar-ios/issues/371))

- Added local OpenCode authorization/quota regressions and manual guided-reconnection
  journeys. Added GitHub Billing permission-disclosure validation and focused iPad
  account-menu diagnostics. Retained results from failed or inconclusive runs instead of
  treating diagnostic subsets as release gates.
  ([#353](https://github.com/HemSoft/codexbar-ios/issues/353)) ([#344](https://github.com/HemSoft/codexbar-ios/issues/344)) ([#381](https://github.com/HemSoft/codexbar-ios/issues/381))

- Made Claude cancellation and stalled Cursor optional-request tests coordinate
  presentation, response, timeout, and cancellation events instead of depending on busy-runner timing.
  ([#330](https://github.com/HemSoft/codexbar-ios/issues/330)) ([#304](https://github.com/HemSoft/codexbar-ios/issues/304))

- Added Google coding authorization with PKCE, secure account-specific storage and
  renewable native-client tokens, with the registered iOS client shipped for guided
  phone setup. Kept the UIKit service out of macOS smoke builds and excluded the one-time development session handoff from Release builds. Live account/quota comparisons
  remain owner-run.
  ([#299](https://github.com/HemSoft/codexbar-ios/issues/299))

- Added a resumable App Store release workflow with source-linked customer copy and
  separate validation, upload, and submission checkpoints. Documented the evidence and
  open questions for future Greptile paid-credit tracking without claiming an
  implemented balance API.
  ([#264](https://github.com/HemSoft/codexbar-ios/issues/264)) ([#397](https://github.com/HemSoft/codexbar-ios/issues/397))

## 1.3.0 - 2026-08-23

### Added

- Added opt-in GitHub service-status monitoring with configurable checks, an
  accessible incident banner, and deduplicated incident, escalation, and
  recovery notifications. Stale or unavailable status data remains visible.
  ([#244](https://github.com/HemSoft/codexbar-ios/issues/244))
- Added a saved History sampling setting, defaulting to two hours, so regular
  usage refreshes no longer create unnecessarily dense history.
  ([#259](https://github.com/HemSoft/codexbar-ios/issues/259))

### Changed

- Clarified that optional GitHub service-status checks use GitHub's public
  endpoint without account credentials or provider usage data, and documented
  the monitoring state kept locally on the device.
  ([#246](https://github.com/HemSoft/codexbar-ios/issues/246))

### Fixed

- Made newly granted banked Codex resets appear even when the main usage
  response has not yet advertised them. ([#251](https://github.com/HemSoft/codexbar-ios/issues/251))
- Let percentage history charts expand above 100% so over-limit usage remains
  visible while preserving the dotted 100% allowance reference.
  ([#250](https://github.com/HemSoft/codexbar-ios/issues/250))
- Made usage Warning and Critical Alert notifications name the provider, saved
  account, metric, current or projected value, and configured threshold. Metric
  selection is deterministic, spend limits use explicit wording, and previews
  remain identifiable when they omit the notification title.
  ([#242](https://github.com/HemSoft/codexbar-ios/issues/242),
  [#249](https://github.com/HemSoft/codexbar-ios/issues/249))

### Developer Experience

- Updated the pinned SwiftLint tooling to 0.65.1, including its fix for
  correctly ignoring URLs in line-length checks.
  ([#256](https://github.com/HemSoft/codexbar-ios/issues/256))
- Made GitHub Copilot credential-replacement tests wait on a deterministic
  browser-auth callback signal, and gave token-error callback tasks enough time
  to run under a loaded simulator instead of racing a five-second timeout.
  ([#248](https://github.com/HemSoft/codexbar-ios/issues/248))
- Made Apple Watch App Store screenshot capture wait for the requested scene,
  reject invalid settle intervals, and choose only storefront-compatible
  simulator sizes. ([#239](https://github.com/HemSoft/codexbar-ios/issues/239))

## 1.2.0 - 2026-08-06

### Fixed

- Prevented refreshes that finish after an account is removed or disabled from
  restoring stale dashboard data, errors, history, alerts, or notifications.
  ([#231](https://github.com/HemSoft/codexbar-ios/issues/231))
- Explained warning and critical card indicators when a hidden metric is the
  cause, including the metric's current value on the card and in VoiceOver.
  ([#227](https://github.com/HemSoft/codexbar-ios/issues/227))

### Added

- Added Greptile as a read-only provider for account-scoped completed-review
  activity, with reliable access to available review history, status details,
  and clear separation from pull-request counts and billing credits across the
  dashboard, history, widgets, and Apple Watch.
  ([#225](https://github.com/HemSoft/codexbar-ios/issues/225))

- Added independently saved, accessible collapse controls to loaded dashboard
  account cards so people can reclaim space while keeping identity, status,
  refresh progress, severity, and account actions visible at a glance.
  ([#219](https://github.com/HemSoft/codexbar-ios/issues/219))
- Added a welcoming first-run dashboard with a prominent Add Account action
  that guides people through provider selection and directly into setup, with
  the same flow available from Settings.
  ([#195](https://github.com/HemSoft/codexbar-ios/issues/195))
- Added configurable Apple Watch complications for inline, circular,
  rectangular, and corner placements, with cached provider usage, honest
  freshness and stale states, and warning or critical context at a glance.
  ([#190](https://github.com/HemSoft/codexbar-ios/issues/190))
- Added a clear path for connecting additional ChatGPT / Codex accounts with
  private browser sign-in, duplicate-account protection, and independently
  preserved credentials and settings for each identity.
  ([#185](https://github.com/HemSoft/codexbar-ios/issues/185))
- Added private, account-free problem and improvement email drafts with
  recognizable subjects, structured editable prompts, optional reviewed
  diagnostics, and copyable fallback details when no email app is configured;
  public GitHub forms remain available as an alternative.
  ([#177](https://github.com/HemSoft/codexbar-ios/issues/177))
- Added previewable, privacy-safe problem diagnostics for provider, widget, and
  Apple Watch failures, with optional technical categories, copy support, and
  bounded GitHub bug-form prefill that never includes account labels,
  credentials, usage, balances, raw responses, or stored snapshots.
  ([#164](https://github.com/HemSoft/codexbar-ios/issues/164))
- Added Apple Watch metric prioritization that follows each iPhone card’s saved
  order, plus per-metric controls to inherit, always show, or always hide a
  metric on Watch without changing the iPhone dashboard.
  ([#146](https://github.com/HemSoft/codexbar-ios/issues/146))
- Added a width-aware, row-aligned two-column dashboard for sufficiently wide
  iPads, with automatic single-column fallbacks and accessible account-card
  reordering. ([#145](https://github.com/HemSoft/codexbar-ios/issues/145))
- Added a live Customize Card editor for rearranging, resizing, restyling,
  showing, and hiding metric tiles, with undo/reset controls, new-metric
  markers, accessible move actions, and reusable layouts across compatible
  accounts. ([#144](https://github.com/HemSoft/codexbar-ios/issues/144))
- Added adaptive metric-tile grids to provider cards, including saved
  automatic, half, and full widths, single-column accessibility layouts, and
  complete per-tile details with available history.
  ([#143](https://github.com/HemSoft/codexbar-ios/issues/143))
- Added a versioned, account-specific metric layout foundation that preserves
  existing visibility and visualization choices while enabling saved tile
  order and adaptive width preferences. ([#142](https://github.com/HemSoft/codexbar-ios/issues/142))
- Added account-specific show/hide controls for every usage, balance, and
  monetary metric on multi-metric dashboard cards, with matching Apple Watch
  visibility and unchanged widget selections. ([#132](https://github.com/HemSoft/codexbar-ios/issues/132))
- Added a Configure Account shortcut to each dashboard card menu so users can
  edit the exact account and refresh its usage without navigating through
  Settings. ([#131](https://github.com/HemSoft/codexbar-ios/issues/131))
- Added compact, accessible subscription-plan badges to ChatGPT / Codex,
  Claude, and GitHub Copilot dashboard cards while preserving custom account
  names and omitting unknown or unverified tiers.
  ([#130](https://github.com/HemSoft/codexbar-ios/issues/130))
- Added current-pace projections to OpenCode Go quota windows when their reset
  boundaries are trustworthy, while leaving ambiguous windows and Zen credit
  balances unprojected. ([#128](https://github.com/HemSoft/codexbar-ios/issues/128))
- Added OpenCode Go subscription tracking for the rolling 5-hour, weekly, and
  monthly usage limits, including provider-reported reset times alongside the
  existing Zen credit balance. ([#122](https://github.com/HemSoft/codexbar-ios/issues/122))
- Added a live, read-only Apple Watch dashboard that mirrors iPhone account
  metrics, visualization choices, ordering, and freshness while keeping the
  last valid snapshot available when the devices disconnect.
  ([#104](https://github.com/HemSoft/codexbar-ios/issues/104))
- Added per-metric dashboard and widget visualization choices with Automatic,
  linear, segmented, ring, dial, and large-number styles that persist separately
  for each configured account. ([#103](https://github.com/HemSoft/codexbar-ios/issues/103))
- Added a discreet banked Codex reset count beside usage limits and a confirmed,
  account-scoped action to use one reset when ChatGPT verifies redemption is
  supported. ([#84](https://github.com/HemSoft/codexbar-ios/issues/84))
- Added per-tile widget links that open CodexBar at the matching provider
  account on the dashboard. ([#63](https://github.com/HemSoft/codexbar-ios/issues/63))
- Added Moonshot (Kimi) as a new provider: paste an API key from
  platform.kimi.ai to track the available credit balance on the dashboard, in
  history, and in widgets, alongside the existing OpenRouter and OpenCode Zen
  balances. ([#66](https://github.com/HemSoft/codexbar-ios/issues/66))

### Changed

- Replaced overlapping usage notifications with one accessible alert model
  whose Warning and Critical Alert percentages can be configured separately
  and apply consistently to current and projected usage across the dashboard,
  widgets, Apple Watch, and complications.
  ([#207](https://github.com/HemSoft/codexbar-ios/issues/207))
- Corrected widget freshness labels so medium, large, and extra-large widgets
  report the age of the oldest usage data they actually display, including
  cached and partially refreshed values. ([#202](https://github.com/HemSoft/codexbar-ios/issues/202))
- Organized Settings into a compact, adaptive category list with focused
  destinations for accounts, dashboard preferences, alerts, widgets, support,
  and recovery while keeping urgent data-recovery needs prominent.
  ([#200](https://github.com/HemSoft/codexbar-ios/issues/200))
- Consolidated Settings account creation into one provider-neutral Add Account
  action at the top of the Accounts section, including for additional ChatGPT /
  Codex accounts. ([#198](https://github.com/HemSoft/codexbar-ios/issues/198))
- Simplified the Settings version label to show only the public app version
  while retaining the internal build number for diagnostics and support.
  ([#170](https://github.com/HemSoft/codexbar-ios/issues/170))
- Replaced the single support link with a quiet Feedback & Support hub for
  reporting problems, suggesting improvements, viewing known issues, reading
  support guidance, and rating CodexBar, with clear public-report privacy
  warnings and safe version and operating-system prefill.
  ([#163](https://github.com/HemSoft/codexbar-ios/issues/163))
- Made public support requests easier and safer with separate structured forms
  for reporting problems and suggesting improvements, plus clearer routing for
  known issues and privacy-sensitive concerns.
  ([#162](https://github.com/HemSoft/codexbar-ios/issues/162))
- Simplified provider cards by moving routine Claude and Cursor context plus
  Cursor alert details into an accessible More Information sheet, and by
  hiding safe projection copy while keeping limit-hit warnings visible.
  ([#160](https://github.com/HemSoft/codexbar-ios/issues/160))
- Let users open a native inventory from the Codex card, inspect each saved
  reset and its localized expiration, and explicitly choose which reset to use.
  ([#101](https://github.com/HemSoft/codexbar-ios/issues/101))
- Restricted browser sign-in callbacks to this device, matched callback hosts
  to each provider's requirements, and made stalled ChatGPT, Claude, and GitHub
  Copilot sign-ins time out cleanly. ([#52](https://github.com/HemSoft/codexbar-ios/issues/52))

### Fixed

- Made ChatGPT, Claude, GitHub Copilot, and Cursor browser sign-in stop safely
  with a retryable error when secure OAuth state or PKCE generation is
  unavailable. ([#217](https://github.com/HemSoft/codexbar-ios/issues/217))
- Fixed Apple Watch dashboard refreshes so reachable phones reply immediately,
  unavailable requests queue for later delivery, and failures explain how to
  recover while preserving the last good dashboard and complication data.
  ([#208](https://github.com/HemSoft/codexbar-ios/issues/208))

- Ensured a newly installed Apple Watch companion requests and receives the
  current dashboard without waiting for an unrelated iPhone data change, while
  preserving the last good snapshot whenever the phone is unavailable.
  ([#191](https://github.com/HemSoft/codexbar-ios/issues/191))
- Made private feedback copy-first and warned before opening an external mail
  composer that it may display and use the currently selected sending account.
  ([#181](https://github.com/HemSoft/codexbar-ios/issues/181))
- Corrected Cursor history to track Total usage by default instead of whichever
  hidden or secondary metric is highest, while adding separate stable history
  series for Total, Auto, API, and On-demand usage.
  ([#178](https://github.com/HemSoft/codexbar-ios/issues/178))
- Kept the current usage percentage prominent in widgets while preserving
  projections as secondary context in fills, details, and severity.
  ([#157](https://github.com/HemSoft/codexbar-ios/issues/157))
- Centered semicircular usage gauges within dashboard and Customize Card
  metric tiles across compact, full-width, and accessibility layouts.
  ([#156](https://github.com/HemSoft/codexbar-ios/issues/156))
- Clarified that OpenRouter credit balances require a sensitive Management API
  Key stored only in Keychain, and now distinguish invalid credentials from
  keys that lack account-credits permission.
  ([#152](https://github.com/HemSoft/codexbar-ios/issues/152))
- Removed duplicated percentages from semicircular usage gauges and centered
  their values while preserving aligned, accessible metric tiles.
  ([#151](https://github.com/HemSoft/codexbar-ios/issues/151))
- Prevented additional iPad windows from starting duplicate dashboard refresh,
  history, alert, widget, and Apple Watch publication work.
  ([#139](https://github.com/HemSoft/codexbar-ios/issues/139))
- Matched Claude's current-session and All models labels, represented the idle
  session state, and kept provider-reported usage-credit balance separate from
  monthly spend headroom. ([#125](https://github.com/HemSoft/codexbar-ios/issues/125))
- Labeled the OpenCode integration as Go + Zen, Go, or Zen based on the
  products available in each workspace while preserving custom account labels.
  ([#127](https://github.com/HemSoft/codexbar-ios/issues/127))
- Let Claude dashboard cards start account-specific sign-in when credentials are
  missing or rejected, preserve the existing credential on cancellation or
  failure, and refresh the card automatically after successful recovery.
  ([#126](https://github.com/HemSoft/codexbar-ios/issues/126))
- Kept the saved GitHub Copilot identity and sign-in method aligned with the
  existing credential when a replacement cannot be stored securely.
  ([#117](https://github.com/HemSoft/codexbar-ios/issues/117))
- Preserved saved account grouping when group data is unreadable, surfaced the
  problem in Settings, and required explicit recovery before replacing damaged
  groups or ungrouping accounts. ([#116](https://github.com/HemSoft/codexbar-ios/issues/116))
- Kept saved accounts and their dashboard settings consistent with Keychain
  credentials when an all-account reset only partially succeeds, while leaving
  failed accounts available to retry. ([#115](https://github.com/HemSoft/codexbar-ios/issues/115))
- Reported damaged saved usage history on the dashboard, preserved its raw data
  until an explicit reset, and resumed recording after recovery.
  ([#109](https://github.com/HemSoft/codexbar-ios/issues/109))
- Surfaced damaged saved account lists in Settings, preserved their raw data and
  Keychain credentials until explicit replacement, and restored normal account
  saving after recovery. ([#108](https://github.com/HemSoft/codexbar-ios/issues/108))
- Hid redundant usage-threshold alert text on Codex dashboard cards while
  preserving threshold notifications and other alert types. ([#94](https://github.com/HemSoft/codexbar-ios/issues/94))
- Made ChatGPT, Claude, and GitHub Copilot browser sign-in callbacks reliable
  when the browser delivers the local HTTP request in multiple pieces.
  ([#87](https://github.com/HemSoft/codexbar-ios/issues/87))
- Kept accounts and their dashboard, history, and widget state available when
  Keychain credential deletion fails so removal can be retried safely.
  ([#86](https://github.com/HemSoft/codexbar-ios/issues/86))
- Kept server-provided details out of GitHub Copilot sign-in errors while
  preserving a safe OAuth error identifier for troubleshooting.
  ([#70](https://github.com/HemSoft/codexbar-ios/issues/70))
- Reported corrupt Keychain credentials and usage-history persistence failures
  instead of treating them as missing or silently discarding history changes.
  ([#65](https://github.com/HemSoft/codexbar-ios/issues/65))
- Show representative sample data in the widget gallery instead of loading the
  current account snapshot while users preview widget configurations.
  ([#62](https://github.com/HemSoft/codexbar-ios/issues/62))
- Kept pending provider-setting edits from overwriting newer Cursor sign-in,
  sign-out, or OpenCode credential changes. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Reported credential-storage failures instead of presenting unsuccessful
  provider sign-ins or credential changes as complete. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Kept provider cards, widgets, and cached usage visible and ordered consistently
  when refreshes fail, queued one follow-up refresh when new triggers arrive
  during an active refresh, and surfaced credential-read errors instead of
  treating them as a missing account.
  ([#60](https://github.com/HemSoft/codexbar-ios/issues/60))
- Stopped routine Claude usage refreshes from sending a billable Messages API
  request when subscription usage is unavailable or incomplete, while keeping
  previously displayed rate-limit windows visible when available.
  ([#58](https://github.com/HemSoft/codexbar-ios/issues/58))
- Preserved Copilot balance, monetary usage, and status details when applying
  configured account labels. ([#57](https://github.com/HemSoft/codexbar-ios/issues/57))
- Kept a newer Claude sign-in from being overwritten when an older token
  refresh finishes at the same time. ([#56](https://github.com/HemSoft/codexbar-ios/issues/56))
- Kept sensitive authorization details out of Claude and Cursor sign-in error
  messages while preserving the HTTP status and safe OAuth error identifier
  needed to understand failures. ([#53](https://github.com/HemSoft/codexbar-ios/issues/53))
- Protected temporary OpenCode ZEN bootstrap credentials before reading them
  and continued removing the staging file after every import attempt.
  ([#54](https://github.com/HemSoft/codexbar-ios/issues/54))

### Developer Experience

- Made the GitHub Copilot concurrent-refresh regression test deterministic
  under parallel CI and bounded synchronization failures to ten seconds.
  ([#235](https://github.com/HemSoft/codexbar-ios/issues/235))
- Finalized version 1.2 release metadata, added deterministic, privacy-safe
  Apple Watch storefront captures alongside the verified iPhone and iPad set,
  and made unattended release validation honor the reviewed pinned build-tool
  plug-in in clean worktrees while selecting an Xcode-compatible Watch runtime
  and keeping loopback-auth tests reliable under parallel release validation.
  ([#239](https://github.com/HemSoft/codexbar-ios/issues/239))
- Prepared privacy-safe, deterministic App Store release notes and a verified
  iPhone and iPad screenshot set for the 1.2 storefront submission.
  ([#237](https://github.com/HemSoft/codexbar-ios/issues/237))
- Added source and built-product release verification that requires the iOS
  app, iOS widget, Watch app, and Watch widget to declare their consistent
  exempt-encryption status. ([#232](https://github.com/HemSoft/codexbar-ios/issues/232))
- Made local and CI watchOS tests deterministically select an installed
  simulator runtime compatible with the active Xcode SDK, with focused selector
  coverage and actionable diagnostics when no compatible device is available.
  ([#229](https://github.com/HemSoft/codexbar-ios/issues/229))
- Updated the README's mutation-testing overview to reflect the complete
  bounded pilot across dashboard sorting and App Review prompt policy logic.
  ([#223](https://github.com/HemSoft/codexbar-ios/issues/223))
- Expanded the manual mutation-testing pilot to deterministic App Review policy
  logic, documented a measured two-file baseline and complete survivor triage,
  and added focused boundary regressions without introducing a CI gate.
  ([#214](https://github.com/HemSoft/codexbar-ios/issues/214))
- Added a strict, zero-violation SwiftLint policy pinned through Swift Package
  Manager, enforced by every Swift-producing build target and an independent
  annotated CI check. ([#210](https://github.com/HemSoft/codexbar-ios/issues/210))
- Made iPhone and Apple Watch connectivity delegate handoffs safe under complete
  Swift concurrency checking, with a repeatable warnings-as-errors build gate.
  ([#203](https://github.com/HemSoft/codexbar-ios/issues/203))
- Condensed the standing agent guide and moved connected-device deployment and
  signing recovery into a focused runbook with live identifier discovery and
  explicit dedicated-keychain safeguards.
  ([#197](https://github.com/HemSoft/codexbar-ios/issues/197))
- Added a repository-local Perfection skill that discovers available simulators,
  runs every supported iOS, SwiftPM, and watchOS build and test gate, treats
  compiler warnings as errors, and preserves consolidated audit diagnostics.
  ([#189](https://github.com/HemSoft/codexbar-ios/issues/189))
- Added deterministic T3 Code project branding using the canonical CodexBar
  iOS app icon. ([#187](https://github.com/HemSoft/codexbar-ios/issues/187))
- Upgraded the pinned CI checkout and failed-test diagnostic upload actions to
  their current v7.0.1 releases while preserving least-privilege access and
  failure-only `.xcresult` retention.
  ([#183](https://github.com/HemSoft/codexbar-ios/issues/183))
- Isolated browser-auth callback ports and network fixtures across parallel test
  workers, and preserved iOS `.xcresult` diagnostics when CI tests fail.
  ([#173](https://github.com/HemSoft/codexbar-ios/issues/173))
- Required every code, documentation, configuration, build, and process change
  to start from a GitHub issue and a clean, synchronized `main`, use an
  issue-specific branch, and deliver the change through a linked pull request.
  ([#169](https://github.com/HemSoft/codexbar-ios/issues/169))
- Stopped repository-change intake after its defining GitHub issue is identified
  unless the user explicitly overrides same-turn implementation.
  ([#193](https://github.com/HemSoft/codexbar-ios/issues/193))
- Added a pinned, sandboxed mutation-testing pilot for dashboard sorting,
  documented its measured baseline and survivor triage, and strengthened
  projection-ordering boundary coverage without adding a blocking CI gate.
  ([#124](https://github.com/HemSoft/codexbar-ios/issues/124))
- Added pull-request and `main` branch CI coverage for iOS unit tests, watchOS
  unit tests, and the SwiftPM smoke harness using simulator destinations
  discovered from each runner. ([#107](https://github.com/HemSoft/codexbar-ios/issues/107))
- Added an embedded watchOS 10 companion target, shared watch app and test
  schemes, a deterministic accessible SwiftUI shell, and simulator-tested watch
  foundation coverage. ([#96](https://github.com/HemSoft/codexbar-ios/issues/96))
- Added deterministic unit coverage for the production widget configuration,
  timeline, entity-query, filtering, and tile-selection logic. ([#97](https://github.com/HemSoft/codexbar-ios/issues/97))
- Added required privacy manifests to the app and widget bundles, including a
  build-time regression check, so App Store submissions declare local and
  app-group preference access correctly. ([#85](https://github.com/HemSoft/codexbar-ios/issues/85))
- Made the simulator runner follow Xcode's latest selected runtime and device,
  hoisted repeated settings formatting work, and removed obsolete
  authentication and parsing code.
  ([#65](https://github.com/HemSoft/codexbar-ios/issues/65))
- Split the monolithic test suite into domain-focused classes with isolated
  network and preference fixtures so independent test groups can run in
  parallel without sharing mutable state.
  ([#64](https://github.com/HemSoft/codexbar-ios/issues/64))
- Split widget configuration, views, accessory layouts, and tile models into
  focused files, and shared provider logos, progress bars, severity colors, and
  currency formatting between the app and widget.
  ([#62](https://github.com/HemSoft/codexbar-ios/issues/62))
- Moved dashboard refresh, alert, widget-sync, ordering, and provider sign-in
  orchestration out of SwiftUI views so those flows can evolve and be tested
  independently. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Consolidated shared provider credential renewal, loopback browser callbacks,
  form encoding, and pasted-secret normalization so authentication fixes can be
  applied consistently across providers. ([#59](https://github.com/HemSoft/codexbar-ios/issues/59))
- Documented why the public GitHub Copilot OAuth application credentials are
  bundled, how PKCE protects sign-in, and limited process-environment credential
  overrides to debug builds. ([#55](https://github.com/HemSoft/codexbar-ios/issues/55))
- Clarified agent guidance for builds, tests, automated PR reviews, iPhone
  deployment, signing recovery, and browser authentication.
- Documented the SwiftPM smoke-test command and kept its provider-coverage check
  aligned with the current seven-provider demo data.

## 1.1.0 - 2026-07-15

### Added

- Added pace-based usage predictions to Cursor's included, Auto, API, and
  on-demand metrics so users can see whether each billing-cycle limit is likely
  to be reached early. ([#46](https://github.com/HemSoft/codexbar-ios/issues/46))
- Added a per-account **Show History** setting so each provider card can hide
  its History section without discarding collected samples. ([#41](https://github.com/HemSoft/codexbar-ios/issues/41))
- Added complete Claude subscription usage details, including all-model and
  model-scoped weekly limits plus currency-aware usage-credit spending and
  monthly headroom shown alongside quota bars. ([#34](https://github.com/HemSoft/codexbar-ios/issues/34))
- Added installed version and build details to Settings, plus a quiet,
  dismissible notice and App Store link when a newer CodexBar release is
  available. ([#20](https://github.com/HemSoft/codexbar-ios/issues/20))
- Added persistent **Rate CodexBar** and **Get Support** actions in Settings,
  plus a restrained native rating request after sustained successful use.
  ([#19](https://github.com/HemSoft/codexbar-ios/issues/19))
- Added richer compact history graphs with latest value, change, range, and
  sample-window context on each usage card. ([#18](https://github.com/HemSoft/codexbar-ios/issues/18))
- Added a tappable expanded history view with a selectable native chart,
  labeled axes, summary statistics, and recent timestamped samples.
- Added account-scoped usage, balance, and severity alert details to each
  dashboard card, including the triggering value, configured threshold, and
  reset context where available. ([#17](https://github.com/HemSoft/codexbar-ios/issues/17))
- Added current-versus-projected context to severity alerts so projected limit
  pressure is distinguishable from current usage.
- Added account and alert-kind metadata to local notification payloads to
  support precise routing and future notification interactions.
- Added a debug alert-demo mode for repeatable visual checks in the simulator.

### Changed

- Kept configured provider cards visible as soon as CodexBar opens, with per-account
  loading, cached-data refresh, failure, and retry states while current usage
  arrives. ([#49](https://github.com/HemSoft/codexbar-ios/issues/49))
- Made Cursor account switching deliberate and reliable: sign-in now uses a
  private browser session, sign-out clears stale identity labels, and an
  existing credential remains active until replacement sign-in succeeds.
  ([#35](https://github.com/HemSoft/codexbar-ios/issues/35))
- Kept ChatGPT / Codex and GitHub Copilot accounts signed in automatically
  instead of prompting users to reauthenticate unnecessarily, while showing
  clearer guidance when access is revoked or permissions are missing.
  ([#26](https://github.com/HemSoft/codexbar-ios/issues/26))
- Displayed reset, projection, history, and billing times in the user's current
  timezone and locale, including refreshed app and widget content after system
  time changes. ([#23](https://github.com/HemSoft/codexbar-ios/issues/23))
- Improved the App Store presentation with clearer screenshots, provider
  wording, privacy expectations, and a more scannable description for people
  evaluating CodexBar before install. ([#22](https://github.com/HemSoft/codexbar-ios/issues/22))
- Updated history presentation to handle empty, single-sample, flat, spiking,
  and balance data with dedicated scales and readable states.
- Updated alert notification titles and bodies to identify the affected account
  and condition more clearly.
- Updated dashboard status indicators to reflect the strongest active alert for
  each card, including user-configured thresholds below the default warning
  severity.
- Kept active alert details visible after notification deduplication, while
  continuing to suppress repeat notifications until the condition recovers.

### Fixed

- Preserved Claude's shared 5-hour session, all-models weekly allowance, and
  model-scoped weekly allowances such as Fable as distinct usage bars with
  their own values, reset times, projections, history, widget entries, and
  alerts, while keeping existing weekly alerts and saved widget tiles intact
  across the upgrade. ([#43](https://github.com/HemSoft/codexbar-ios/issues/43))
- Kept the Codex 5-hour usage metric recognizable when ChatGPT reports a
  slightly varied window duration, while quietly showing only the available
  weekly limit when ChatGPT temporarily omits the 5-hour window.
  ([#38](https://github.com/HemSoft/codexbar-ios/issues/38))

### Developer Experience

- Added deterministic App Store screenshot capture automation for the six
  marketing scenes across iPhone 17 Pro Max and iPad Pro 13-inch (M5),
  including readiness polling, stable filenames, size checks, and Fastlane
  mirroring. ([#22](https://github.com/HemSoft/codexbar-ios/issues/22))
- Restored Swift 6 package-build compatibility for the main-actor notification
  service singleton.
- Added dedicated CodexBar signing-keychain reset and scoped-command helpers.
- Kept the lock-on-sleep signing keychain out of the normal macOS keychain
  search list, preventing unrelated system services from repeatedly requesting
  its password after wake.
- Documented the verified iPhone deployment and signing-recovery workflow in
  `AGENTS.md`.
- Established changelog maintenance rules so App Store release notes and
  marketing copy are derived from accurate, versioned product history.
- Removed the Claude reviewer GitHub Actions workflow after upstream failures
  made it an unreliable merge-readiness signal; Codex and CodeRabbit remain the
  primary automated review loop.
