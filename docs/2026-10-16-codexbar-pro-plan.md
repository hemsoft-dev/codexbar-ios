# CodexBar Pro plan for iOS and watchOS

Plan for [issue #441](https://github.com/hemsoft-dev/codexbar-ios/issues/441), written October 16, 2026. CodexBar 2.0 moves the iOS app, with its watchOS companion and widgets, from a US$3.99 one-time purchase to a free download plus **CodexBar Pro**. There are no ads.

Franz made the product decisions on 2026-10-16; they are recorded in the issue's Decisions table. This document turns them into states, rules, a launch sequence and follow-up work. Other platforms are planned separately in [#459](https://github.com/hemsoft-dev/codexbar-ios/issues/459).

Apple claims link to official Apple pages, checked on October 16, 2026. Where Apple documents nothing, the text says **unverified** and the plan picks the safe behavior. Revenue figures are estimates from a reproducible model, not forecasts.

## Contents

- [Decisions this plan implements](#decisions-this-plan-implements)
- [Entitlement model](#entitlement-model)
- [Recognizing original purchasers](#recognizing-original-purchasers)
- [Launch-day sequence](#launch-day-sequence)
- [Free tier, limits and downgrade](#free-tier-limits-and-downgrade)
- [App Store Connect setup](#app-store-connect-setup)
- [Disclosures](#disclosures)
- [Economics](#economics)
- [codexbar.net at launch](#codexbarnet-at-launch)
- [Rollout and success criteria](#rollout-and-success-criteria)
- [Follow-up implementation issues](#follow-up-implementation-issues)
- [Decisions still needed from Franz](#decisions-still-needed-from-franz)
- [Sources](#sources)

## Decisions this plan implements

| Topic | Decision |
| --- | --- |
| Model | Free tier plus CodexBar Pro. No ads on any platform. |
| Free tier | One provider and one account, chosen by the user. Dashboard and 7 days of history. |
| Pro | Unlimited providers and accounts, widgets, the watch app, full history and alerts. |
| Prices (US base) | US$1.99/month, US$14.99/year, US$29.99 one-time lifetime unlock. |
| Trial | 7-day free trial on the yearly plan only. |
| Original purchasers | Lifetime Pro, including Family Sharing members of the original paid app. This plan narrows the family promise to members who install before the cutover `T`, pending Franz's approval (decision 6). |
| Family Sharing on new Pro products | Off at launch. |
| Downgrade | Accounts beyond the free limit stop refreshing. Credentials and settings are kept, and the user picks the active account. |
| Release | Version 2.0.0, as soon as implementation and App Store setup are ready. |
| Terms | Apple's standard EULA. |
| Small Business Program | Franz publishes as an individual, which qualifies. Enroll before 2.0 ships. |

## Entitlement model

CodexBar has no server, so every Pro check runs on the device with StoreKit 2. There are four sources:

1. **`AppTransaction`**: proves the original download and identifies original purchasers ([AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction)).
2. **`Transaction.currentEntitlements`**: the active subscription or lifetime unlock. It lists non-consumables and subscriptions that are subscribed or in billing grace, and leaves out refunded or revoked products ([currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)).
3. **`Transaction.updates`**: a listener started at launch that applies renewals, refunds, revocations and purchases made on another device ([updates](https://developer.apple.com/documentation/storekit/transaction/updates)).
4. **`Product.SubscriptionInfo.Status`** for the subscription group: the renewal state, read at launch and observed through its status update sequence ([Subscription status](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status-swift.struct)). Its verified `renewalInfo` is the only source for billing retry, the grace-period end and `willAutoRenew`. `currentEntitlements` shows access but not why, so it can't tell a grace-period subscriber from an ordinary one.

Every verified transaction is **finished** with `Transaction.finish()` once the entitlement has been saved to the cache and published. This applies to transactions from `Product.purchase()` and from the updates listener. StoreKit redelivers unfinished transactions at every launch ([finish()](https://developer.apple.com/documentation/storekit/transaction/finish%28%29)). Unverified transactions are never finished as granted.

Only **verified** results grant Pro. StoreKit checks the JWS signature on the device without a network connection ([WWDC21: Meet StoreKit 2](https://developer.apple.com/videos/play/wwdc2021/10114/)). An unverified result never grants Pro and offers a restore button, following Apple's guidance ([WWDC22: What's new with in-app purchase](https://developer.apple.com/videos/play/wwdc2022/10007/)).

A single `ProEntitlement` service reduces these sources to one value, which the app publishes:

- **Pro reason:** `originalPurchaser`, `lifetime`, `yearly`, `monthly`, `trial`, `billingGrace`, or `none`.
- **`expiresAt`:** when the access ends, for subscriptions.
- **`verifiedAt`:** when StoreKit last confirmed it.

It is cached in the App Group (`group.com.hemsoft.CodexBarIOS`) so widgets and the watch publisher read the same answer. The cache holds no purchase identifiers and no Apple Account data.

### States

| State | How it is detected | Pro? | What the user sees |
| --- | --- | --- | --- |
| Free | No qualifying `AppTransaction`, no entitlement | No | Free tier; Pro offered at the limit points |
| Trial | Yearly entitlement whose transaction carries the introductory free-trial offer | Yes | Pro; Settings shows when the trial ends and the yearly price that follows |
| Monthly | Active monthly entitlement | Yes | Pro; renewal date in Settings |
| Yearly | Active yearly entitlement | Yes | Pro; renewal date in Settings |
| Lifetime | Verified lifetime non-consumable | Yes | Pro, with no renewal |
| Original purchaser | `AppTransaction` qualifies (see next section) | Yes, permanently | Pro, plus a one-time "Thanks for buying CodexBar: you have lifetime Pro" notice |
| Billing grace | Subscription status is `.inGracePeriod`, or its renewal info shows billing retry with a `gracePeriodExpirationDate` in the future ([isInBillingRetry](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/isinbillingretry)) | Yes, until the grace period ends | Pro, plus a banner that links to Apple's subscription management to fix the payment |
| Billing retry without grace | Subscription status is `.inBillingRetryPeriod`, with no grace date | No | Free tier, plus the same payment banner. Pro returns automatically if Apple recovers the payment. |
| Expired | Subscription past `expirationDate` and not renewed | No | Free tier; downgrade rules apply |
| Refunded or revoked | Product drops out of `currentEntitlements`, or `Transaction.updates` delivers a `revocationDate` | No, from the next update | Free tier; downgrade rules apply. Original-purchaser status is lost only if Apple revokes the original app purchase. |
| Offline startup | StoreKit cannot refresh | See below | Last verified state, within limits |

Two states can apply at once. For example, an original purchaser who also subscribed stays Pro if the subscription lapses. In that case the app shows only "Lifetime Pro" and points to Apple's subscription management so the user can cancel the subscription they no longer need. CodexBar never cancels a subscription itself.

### Offline startup

StoreKit keeps signed transactions on the device. How long they stay readable without a network is **unverified** in Apple's documentation, so the app also caches its last verified decision:

- **Original purchaser and lifetime:** the cached Pro access has no time limit, until StoreKit reports a revocation.
- **Subscriptions and trial:** cached Pro access lasts until the signed `expirationDate`, plus the billing grace period if one is active, plus a **3-day offline allowance**. After that the app falls back to the free tier until StoreKit can be reached.
- **No verified decision ever cached:** free tier. A failed launch never grants Pro.

### Restore, reinstall and new devices

- On reinstall or a new device, transactions are available automatically at first launch ([AppStore.sync](https://developer.apple.com/documentation/storekit/appstore/sync())). The `AppTransaction` purchase date also survives a reinstall ([originalPurchaseDate](https://developer.apple.com/documentation/storekit/apptransaction/originalpurchasedate)).
- Settings and the paywall have a **Restore Purchases** button, as guideline 3.1.1 requires. It calls `AppStore.sync()`. If the `AppTransaction` is missing or unverified, it also calls `AppTransaction.refresh()`, which may show a sign-in prompt. Both are called only after the user taps the button, as Apple instructs ([refresh](https://developer.apple.com/documentation/storekit/apptransaction/refresh())).
- Nobody can be charged twice:
  - The paywall hides the lifetime purchase and the subscriptions while the user already has Pro for any reason.
  - Monthly and yearly are in one subscription group, so Apple allows only one active subscription in it.
  - A subscriber can buy lifetime only from the Settings "Switch to lifetime" row, and only once the subscription will not renew: the verified `renewalInfo.willAutoRenew` is `false`.
    - While auto-renew is still on, the row's buy button is disabled. It says "Turn off auto-renew first" and opens Apple's subscription management sheet.
    - When auto-renew is off, the row shows the date the subscription ends and states that the paid period isn't refunded. Only then can the user buy lifetime.

    The worst case is overlapping access for time that was already paid, never another subscription charge after the lifetime purchase.

## Recognizing original purchasers

### Build numbers that shipped

On iOS, `originalAppVersion` is the **build number** (`CFBundleVersion`), not the marketing version ([originalAppVersion](https://developer.apple.com/documentation/storekit/apptransaction/originalappversion)). These builds shipped, according to `APP-STORE.md` and git history:

| Version | Build | Price |
| --- | --- | --- |
| 1.0 | 1 | US$3.99 |
| 1.1 | 1 | US$3.99 |
| 1.2 | 2 | US$3.99 |
| 1.3 | 3 | US$3.99 |
| 1.4.0 | 4 | US$3.99 (waiting for review) |

`CURRENT_PROJECT_VERSION` is still `4` on `main`. **2.0.0 must ship as build 5 or higher.** Otherwise a 2.0 download would carry the same build number as a 1.4.0 purchase.

### Rule

A user is an original purchaser when all of these hold:

1. `AppTransaction.shared` is **verified**.
2. The app transaction has **no `revocationDate`**. A refunded or revoked app purchase never qualifies.
3. `environment == .production`. In the sandbox, which also covers TestFlight and App Review, `originalAppVersion` is always `1.0` and `originalPurchaseDate` is always 2013-08-01. Without this check every tester and reviewer would get lifetime Pro and nobody could test the paywall.
4. **Either** check passes:
   - **Build:** `originalAppVersion`, parsed as an integer, is `≤ 4`. Compare numbers, not strings: Apple's sample compares strings, which would put `"10"` before `"4"`.
   - **Date:** `originalPurchaseDate` is before the **cutover instant** compiled into 2.0. That instant is the end of the paid era (see the next section).

The two checks are combined with **OR** on purpose:

- The build check covers everyone who bought 1.0 through 1.4.0, whenever they bought it.
- The date check covers anyone who paid US$3.99 for 2.0 itself in the short window between the 2.0 release and the price change.

A free download can't pass either check:

- It always arrives after the price change, so it fails the date check.
- It always gets build 5 or later, because the launch sequence keeps the price at US$3.99 until 2.0 is the build being served everywhere.

A version string that isn't a plain integer, such as a marketing-style `1.4.0`, is compared as a marketing version below `2.0`. This matters because the app is also available on Mac (Apple silicon) and Vision Pro. On macOS, Apple documents `originalAppVersion` as the marketing version, and it is **unverified** what an iPhone app running on a Mac reports.

### Edge cases

| Case | Outcome |
| --- | --- |
| Bought 1.x, reinstalls or moves to a new device | Original purchaser. The purchase date and original version survive a reinstall. |
| Bought 2.0 at US$3.99 before the price change | Original purchaser, through the date check. |
| Free download of 2.0 | Not an original purchaser; free tier. |
| Original purchase refunded | The rule requires no `revocationDate`, so a revoked app transaction never qualifies, and Pro is removed when StoreKit reports the revocation. Whether Apple sets `revocationDate` for every app-purchase refund is **unverified**. If it doesn't, the user keeps Pro: being generous here costs one user, while being strict could lock out a paying customer. |
| Family Sharing member of the original paid app | Lifetime Pro, **for members who install CodexBar before `T`**. **Unverified:** whether a family member's `AppTransaction` carries the organizer's purchase date or their own download date. The plan assumes their own download date. After the price change, a family member's free download can't be told apart from anyone else's on the device, and CodexBar has no server to check family membership. So the plan closes the gap before `T` instead (see [Family Sharing members](#family-sharing-members)). A member who first installs after `T` gets the free tier unless support sends a lifetime offer code. Franz must accept this narrowed promise (see [Decisions still needed](#decisions-still-needed-from-franz)). |
| Sandbox, TestFlight, Xcode or App Review | Never an original purchaser. Debug builds get a developer-only override for testing. |
| Mac or Vision Pro install of the iPhone app | Same rule. Original version strings that aren't integers go through the marketing-version comparison. |
| `AppTransaction` unavailable (signed out, offline on first launch) | Free tier, plus "Restore Purchases" to call `refresh()`. A cached verified decision still applies. |

### Family Sharing members

Members who install CodexBar through Family Sharing before `T` pass the date check, and also the build check if they installed 1.x. To get as many members as possible to install in time:

- The one-time 2.0 thank-you notice for original purchasers says: "Family members can get lifetime Pro too: have them install CodexBar from the App Store before <T, local date>."
- The 2.0 What's New text and the App Store promotional text repeat this until `T`.
- `SUPPORT.md` explains the cutoff and the offer-code route for members who missed it.

### Support fallback

A paying customer the rule misses can still receive lifetime Pro. Support sends a **one-time offer code for the lifetime product, set to free**. Since March 26, 2026, Apple no longer creates promo codes for in-app purchases. Offer codes replaced them and now cover non-consumables ([Apple Developer News](https://developer.apple.com/news/?id=gf6mgrs6), [offer codes for in-app purchases](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-offer-codes-for-in-app-purchases/)). The plan doesn't depend on this; it is a manual safety net.

## Launch-day sequence

Apple can't tie a price change to the release of a version. A price change starts at different local times in each storefront and can take up to 24 hours to show ([price change scheduling](https://developer.apple.com/help/app-store-connect/manage-app-pricing/schedule-price-changes-for-apps/), [regional start times](https://developer.apple.com/help/app-store-connect/reference/app-store-pricing-and-availability-start-times-by-region/)). After a manual release, a version can also take up to 24 hours to appear ([release options](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)).

So the sequence keeps the paid price until 2.0 is live everywhere, then drops the price comfortably before the cutover instant compiled into the app.

1. **Before submitting 2.0.** Pick the cutover instant `T`. Recommendation: about 10 days after the planned submission, at 00:00 UTC.
   - Compile `T` into 2.0.
   - Set the build number to 5 or higher.
   - Check that the 1.4.0 review has finished, so 2.0 doesn't queue behind it.
2. **Submit 2.0 with all in-app purchase products** in the same submission. The first subscription and non-consumable must be submitted with a new app version ([submit an in-app purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)).
   - Set the release option to **Manual release**.
   - Turn phased release **off**. Phased release only delays automatic updates, and new downloads always get the current version ([phased release](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/)).
   - Keep the price at US$3.99.
3. **When 2.0 is approved,** release it manually, but only if at least **6 days** remain before `T`. That leaves 48 hours for the release to reach every storefront, 72 hours for the price change, and a day of margin. Wait the 48 hours, and confirm in several storefronts that the App Store serves 2.0.
4. **Schedule the price change to Free** to take effect **before `T` in every storefront**. Recommendation: about 72 hours before `T`, so the latest-starting region is also free well before `T`.
   - Paid downloads in that window pass the date check and get Pro.
   - Free downloads in that window also pass the date check. That's a deliberate, short giveaway, and much cheaper than refusing a paying customer.
5. **After `T`:**
   - Verify the free download path, the paywall, the trial and Restore on a production device.
   - Franz confirms that an existing 1.x purchase on his device shows lifetime Pro.

**If approval comes too late,** with fewer than 6 days left before `T`, don't release 2.0. Reject the approved build while it is Pending Developer Release, upload a build of 2.0 with a later `T`, and resubmit. Apple requires a version to be Ready for Distribution before a new version can be created ([create a new version](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version)), so this has to be a replacement build of 2.0, not a 2.0.1.

Because releasing 2.0 and changing the price are both manual, three rules close the sequence:

- **The price never goes free while the App Store still serves 1.4.0.** The 48-hour wait and storefront checks cover this.
- **The price never goes free after `T`.** The price change is always scheduled before `T`.
- **2.0 is never sold at US$3.99 after `T`.** Releasing only with at least 6 days left keeps paid 2.0 buyers on the date check.

### Rollback

- **Before the price change:** paid 2.0 buyers qualify through the date check until `T`, so nothing is lost before then. If the price change has to be postponed past `T`, stop selling at `T`: remove the app from sale until a 2.0.1 with a later `T` is live. Otherwise, people who pay for 2.0 after `T` would fail both checks. A blocking bug can be fixed with 2.0.1, because 2.0 is then Ready for Distribution.
- **After the price change:**
  - Pricing can return to US$3.99, but people who downloaded for free stay free-tier users. That is correct, because they never paid.
  - If original purchasers are wrongly denied, ship a fix and send a free lifetime offer code to anyone who writes to support.
  - Pro products can be removed from sale. Existing subscribers keep access until expiry; Apple handles that.

## Free tier, limits and downgrade

### Limits

| Feature | Free | Pro | Where it is enforced |
| --- | --- | --- | --- |
| Accounts | One active account, of any provider, chosen by the user | Unlimited | `ProviderConfigurationStore.addAccount` and the Add Account flow (`SettingsView` `AddAccountFlowState.select`, the Greptile add path), plus one refresh predicate in `UsageRefreshService` (`performRefresh`, `refresh(configuration:)`, `updateCurrentConfigurations`) |
| Dashboard and cards | Yes | Yes | Not gated |
| History | Last 7 days | Full: Today, 3D, 7D, 1M, 3M | `UsageHistoryRange` picker and `filtered(to:)`. 1M and 3M show as locked segments. Stored data isn't deleted, so upgrading shows it right away. |
| Widgets | Locked placeholder: "Unlock widgets with CodexBar Pro" | Live | The phone publisher writes a locked flag to the App Group, and `CodexBarWidgetView` renders the locked state. The gallery preview stays as it is. |
| Watch app and complications | Locked state: "Unlock the watch app with CodexBar Pro on iPhone" | Live | `WatchSnapshotPublisher` sends an explicit locked snapshot. It doesn't simply stop sending, which would leave stale data on the watch. |
| Usage alerts | Off; the toggle opens the Pro screen | Yes | `DashboardOrchestrator.processUsageAlerts` |
| GitHub status notices | Yes | Yes | Not gated. These are service-health notices, not usage features. |
| Subscription renewal pills and resets | Yes, for the active account | Yes | Not gated |

Linked hidden accounts (the Antigravity half of a Gemini account) don't count toward the limit.

### Downgrade

Downgrade happens when Pro ends: on expiry, refund or revocation, or the end of billing grace.

- Use a **separate, derived "paused by plan" state**. Never write the account's `isEnabled` flag. The user's own Enabled choices must survive a downgrade and an upgrade unchanged.
- A new stored value, `freeActiveAccountID`, records the user's choice. If it isn't set, the first visible enabled account in dashboard order is the default.
- The next time the app opens after a downgrade, a one-time sheet asks the user to **choose the account that keeps refreshing**. It lists every account with its last known values.
- Paused accounts:
  - keep their credentials, metric choices, order and history;
  - stop refreshing;
  - show their last result, dimmed, with a lock and a "Paused: CodexBar Pro" label;
  - are left out of widgets, the watch and alerts.

  They don't go through the existing disabled-account pruning, which would discard their cached results.
- **Resubscribing restores everything immediately,** with no reconfiguration.
- **Users who already have several accounts when 2.0 installs** (all of them are original purchasers today) see nothing, because they're Pro. Any Pro user whose Pro later ends follows the same downgrade path.

### Upgrade prompts

The Pro screen opens only from a user action:

- Add Account when the limit is reached;
- a locked history segment;
- the alerts toggle;
- a locked widget or watch state;
- Settings > CodexBar Pro.

There are no launch-time interstitials and no repeated nags.

## App Store Connect setup

- **Subscription group** "CodexBar Pro", with two subscriptions:
  - `com.hemsoft.CodexBarIOS.pro.yearly`: level 1, US$14.99, 7-day free introductory offer;
  - `com.hemsoft.CodexBarIOS.pro.monthly`: also level 1, US$1.99.

  Both unlock the same features, so they share one level. Switching between them is a crossgrade that takes effect at the next renewal, not an upgrade or downgrade ([auto-renewable subscription information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information/)).

  A customer can redeem one introductory offer per group, so the yearly-only trial works as decided ([introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/)). The app checks `isEligibleForIntroOffer` and shows trial wording only when it returns true.
- **Non-consumable** `com.hemsoft.CodexBarIOS.pro.lifetime`: US$29.99. Subscriptions can be offered alongside one-time purchases (guideline 3.1.2(a)).
- **Prices.** US is the base storefront. Apple generates prices for the other storefronts automatically for the lifetime unlock ([set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price)). For subscriptions it suggests comparable prices when they're set ([subscription pricing](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions/)). Apple's periodic tax and currency adjustments don't change auto-renewable subscription prices ([January 2026 notice](https://developer.apple.com/news/?id=gvnljl3f)).
- **Family Sharing:** off for all three products. It can't be turned off once enabled ([Family Sharing](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/)).
- **Multiseat purchasing,** on by default since September 2026, stays at its default for now. It matters only for organizations buying several seats, and only the group purchaser can share. Revisit if Family Sharing is ever enabled ([Apple news](https://developer.apple.com/news/?id=likeohx4)).
- **Billing grace period:** on, **16 days**, for all renewals ([billing grace period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions)).
- **Localization:** en-US names and descriptions for the group and each product. Other locales follow the app's metadata locales.
- **Review screenshots:** one per product, showing the Pro screen with prices ([in-app purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)).
- **Review notes:** explain that reviewers see the free tier because the sandbox never qualifies as an original purchaser, and list how to reach the Pro screen.
- **Small Business Program:** Franz enrolls as Account Holder before 2.0 ships. New enrollment takes effect from the fiscal month after approval ([Small Business Program](https://developer.apple.com/app-store/small-business-program/)).
- **App price:** US$3.99 until step 4 of the launch sequence, then Free.

## Disclosures

| Item | Change |
| --- | --- |
| Pro screen in the app | Product title, length and price. The billed amount is the most prominent price. Trial wording states the 7-day length and the US$14.99/year price after the trial. Links to the Privacy Policy and Terms of Use (Apple's standard EULA) on the purchase screen ([guideline 3.1.2](https://developer.apple.com/app-store/review/guidelines/#subscriptions), [DPLA Schedule 2 §3.8(b)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/), [subscription guidance](https://developer.apple.com/app-store/subscriptions/)) |
| Settings > CodexBar Pro | Current plan, renewal or expiry date, Manage Subscription (Apple's sheet), Restore Purchases, Privacy Policy, Terms of Use |
| App Store description | Free tier and Pro features. A line linking the Terms of Use (Apple's standard EULA URL) and the Privacy Policy, which Apple requires in metadata for subscription apps |
| `APP-STORE.md` | Replace the US$3.99 release policy with the free and Pro pricing. Add the launch sequence and the cutover instant. |
| `PRIVACY.md` | New "Purchases" section: Apple processes payments, and CodexBar only checks entitlements on the device. Its App Group cache holds the plan state, not purchase or account identifiers. There is no server, analytics or ads. |
| App Privacy label | Stays **Data Not Collected**. Data processed only on the device isn't "collected", and developers aren't responsible for disclosing data Apple collects ([App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)). |
| `CHANGELOG.md` | `2.0.0 - Unreleased` describes the free tier, CodexBar Pro, and lifetime Pro for original purchasers. Add it only when it ships, never as a promise. |
| Original purchasers | A one-time in-app notice on first 2.0 launch: "Thanks for buying CodexBar. You have lifetime Pro: nothing to do." Until `T`, it also asks them to have family members install CodexBar before the cutover date. The 2.0 What's New text says the same. |
| `SUPPORT.md` | How to restore, how original purchasers are recognized, and how to ask for help if Pro is missing |

## Economics

### Sourced inputs

| Input | Value | Source |
| --- | --- | --- |
| Total App Store proceeds to date | US$197 | Franz, App Store Connect, 2026-10-16 |
| Paid purchases to date | About 50–70 | US$197 divided by the per-sale proceeds at 15% or 30% commission |
| Pro prices | US$1.99 / US$14.99 / US$29.99 | Decision |
| Commission | 15% (Small Business Program) or 30%. Renewals after a subscriber's first paid year drop to 15% under standard terms. | [Small Business Program](https://developer.apple.com/app-store/small-business-program/), [DPLA Schedule 2](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) |

### Estimated inputs

These aren't measured and should be replaced with real values after launch:

| Input | Low | Base | High |
| --- | ---: | ---: | ---: |
| New downloads per month after going free | 100 | 300 | 1,000 |
| Share of new downloads that pay | 2% | 4% | 6% |

Every scenario also assumes:

- payers split 40% monthly, 45% yearly and 15% lifetime;
- 15% of monthly subscribers cancel each month;
- no yearly renewals within the first 12 months.

### Results

Run `python3 scripts/pro-economics/model.py`. Each option (`--downloads`, `--conversion`, `--mix`, `--monthly-churn`, `--commission`) changes one input, and the script recomputes the table.

At 15% commission:

| Scenario | Downloads/month | Conversion | Payers/month | Proceeds, first 12 months | Proceeds, month 12 |
| --- | ---: | ---: | ---: | ---: | ---: |
| low | 100 | 2% | 2 | US$294 | US$27 |
| base | 300 | 4% | 12 | US$1,763 | US$161 |
| high | 1,000 | 6% | 60 | US$8,814 | US$806 |

At 30% commission (`--commission 0.30`):

| Scenario | Proceeds, first 12 months | Proceeds, month 12 |
| --- | ---: | ---: |
| low | US$242 | US$22 |
| base | US$1,452 | US$133 |
| high | US$7,258 | US$663 |

Even the low scenario beats the US$197 earned so far. Enrolling in the Small Business Program is worth about 21% more proceeds in every scenario. Download volume and conversion are the inputs to measure first.

## codexbar.net at launch

`codexbar.net` doesn't resolve today: it has no DNS records as of October 16, 2026. **2.0 must not depend on it.** The App Store privacy and support URLs stay on GitHub (`PRIVACY.md` and `SUPPORT.md`), and the Terms of Use link points to Apple's standard EULA.

If Franz registers and publishes the domain before launch, it holds:

- a one-page product site with App Store download links;
- a pricing table matching the decided prices;
- the privacy policy and a Terms page that links to Apple's standard EULA.

Only then may the App Store marketing URL point to it. No web checkout at launch: other-platform billing is [#459](https://github.com/hemsoft-dev/codexbar-ios/issues/459).

## Rollout and success criteria

Measured from App Store Connect (App Analytics, Sales and Trends, subscription reports) for the first 60 days after `T`. No in-app analytics are added.

| Measure | Healthy | Act if |
| --- | --- | --- |
| Download growth versus the paid era | 3× or more | Under 2×: review the App Store copy and screenshots |
| Download-to-paid conversion | 3% or more | Under 1.5%: review where the free-tier limits sit and the Pro screen copy |
| Trial-to-paid conversion (yearly) | 40% or more | Under 25%: review the trial wording and the value shown during the trial |
| Refund rate | Under 5% of purchases | Above 5%: check for confused original purchasers or misleading copy |
| Rating and reviews | Stays at or above the current average, with no "lost features I paid for" reviews | Any such review: reply, send a lifetime offer code, and fix detection |
| Original purchasers wrongly shown as free | Zero support reports | Any report: an offer code plus a fix |

## Follow-up implementation issues

Each is a bounded issue with its own PR. The arrows show dependencies.

1. **StoreKit 2 entitlement service:** `ProEntitlement` state, verification, the `Transaction.updates` listener and the subscription status updates listener, `Transaction.finish()` after the entitlement is saved and published, App Group cache, offline rules, debug override, and a StoreKit configuration file for local tests. Unit tests use an injected transaction source, because the sandbox can't produce production `AppTransaction` values.
2. **Original-purchaser detection** (→1): the build-or-date rule, the non-revoked and production-only checks, integer and marketing-version parsing, the compiled cutover instant, and the one-time thank-you notice, including the Family Sharing install-before-`T` message.
3. **Free-tier limits and downgrade** (→1):
   - the account limit at Add Account;
   - the refresh predicate and the "paused by plan" state with `freeActiveAccountID`;
   - the account chooser sheet;
   - the history range lock;
   - the alerts gate.
4. **Widget and watch Pro states** (→1): the locked widget view and the locked watch snapshot and view, with the gallery preview unchanged.
5. **Pro screen, restore and Settings** (→1):
   - the Pro screen with the three products;
   - trial eligibility and the required disclosures;
   - Restore Purchases and Manage Subscription;
   - the billing-problem banner;
   - Settings > CodexBar Pro.
6. **App Store Connect setup, disclosures and changelog** (→2, 3, 4, 5):
   - the products, group, grace period and review screenshots;
   - updates to `APP-STORE.md`, `PRIVACY.md` and `SUPPORT.md`;
   - the App Store description;
   - the 2.0.0 changelog entry;
   - build number 5 or higher.
7. **2.0 release and price change** (→6): carry out the launch sequence above with the release skill, and record `T` and every timestamp in `APP-STORE.md`.

UI issues (3, 4 and 5) need current-head screenshots in their PRs of the free, Pro, limit, restore, expired or offline, and original-purchaser states, plus a purchase-and-restore recording on a StoreKit-configured simulator.

## Decisions still needed from Franz

1. **Small Business Program:** confirm enrollment, or apply as Account Holder.
2. **Cutover instant `T`:** pick it once a submission date is known. The default is submission plus about 10 days, at 00:00 UTC.
3. **Offline allowance:** 3 days past a subscription's signed expiry is proposed.
4. **GitHub status notices:** stay free, as proposed. Say if they should be Pro.
5. **codexbar.net:** register and publish before launch, or leave it out of 2.0.
6. **Family Sharing promise:** accept that lifetime Pro for family members of original purchasers covers **members who install CodexBar before `T`**, with offer codes from support for anyone who misses it. On the device, after the price change, a family member's free download looks the same as any other free download, and CodexBar has no server to check family membership.
7. **Family Sharing check:** after launch, confirm with a family member's device that original-purchaser Pro carries over. This check is pending for Franz.

## Sources

Apple, checked October 16, 2026:

- StoreKit
  - [AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction): [originalAppVersion](https://developer.apple.com/documentation/storekit/apptransaction/originalappversion), [originalPurchaseDate](https://developer.apple.com/documentation/storekit/apptransaction/originalpurchasedate), [shared](https://developer.apple.com/documentation/storekit/apptransaction/shared), [refresh()](https://developer.apple.com/documentation/storekit/apptransaction/refresh())
  - [Supporting business model changes by using the app transaction](https://developer.apple.com/documentation/storekit/supporting-business-model-changes-by-using-the-app-transaction)
  - [Transaction.currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements), [Transaction.updates](https://developer.apple.com/documentation/storekit/transaction/updates)
  - [RenewalInfo.isInBillingRetry](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/isinbillingretry), [isEligibleForIntroOffer](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/iseligibleforintrooffer)
  - [Subscription status](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status-swift.struct), [Transaction.finish()](https://developer.apple.com/documentation/storekit/transaction/finish%28%29)
  - [AppStore.sync()](https://developer.apple.com/documentation/storekit/appstore/sync()), [Supporting Family Sharing in your app](https://developer.apple.com/documentation/storekit/supporting-family-sharing-in-your-app)
- App Store Connect Help
  - Pricing: [Schedule price changes](https://developer.apple.com/help/app-store-connect/manage-app-pricing/schedule-price-changes-for-apps/), [regional start times](https://developer.apple.com/help/app-store-connect/reference/app-store-pricing-and-availability-start-times-by-region/), [Set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price)
  - Releases: [create a new version](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version), [release options](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/), [phased release](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/)
  - Subscriptions: [auto-renewable subscription information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information/), [introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/), [billing grace period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions), [subscription pricing](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions/)
  - In-app purchases: [Family Sharing](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/), [submit an in-app purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/), [in-app purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)
- Policy
  - [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (3.1.1, 3.1.2, 2.5.18)
  - [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
  - [Auto-renewable subscriptions](https://developer.apple.com/app-store/subscriptions/)
  - [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
  - [Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- Apple news and videos
  - [Multiseat purchasing](https://developer.apple.com/news/?id=likeohx4), [in-app purchase promo codes replaced by offer codes](https://developer.apple.com/news/?id=gf6mgrs6), [subscription price adjustments, January 2026](https://developer.apple.com/news/?id=gvnljl3f)
  - [WWDC21 Meet StoreKit 2](https://developer.apple.com/videos/play/wwdc2021/10114/), [WWDC22 What's new with in-app purchase](https://developer.apple.com/videos/play/wwdc2022/10007/), [WWDC25 What's new in StoreKit](https://developer.apple.com/videos/play/wwdc2025/241/)

**Not verified from an official source, and handled conservatively above:**

- whether Family Sharing members of the paid app get their own or the organizer's purchase date in `AppTransaction`;
- what an iPhone app running on a Mac reports as `originalAppVersion`;
- how long StoreKit entitlements stay readable offline;
- whether app-purchase refunds appear as an `AppTransaction` revocation;
- whether StoreKit works directly inside widget extensions. The plan avoids this by having the app publish the decision to the App Group.
