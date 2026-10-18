# Local CodexBar Pro tests

The entitlement foundation for [#464](https://github.com/hemsoft-dev/codexbar-ios/issues/464)
reads verified StoreKit app purchases, current entitlements, transaction updates
and subscription statuses. Original-purchaser eligibility is supplied separately
by [#465](https://github.com/hemsoft-dev/codexbar-ios/issues/465). This foundation
does not enforce the free tier or add purchase screens.

Run the injected state and delivery regressions locally:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --filter ProEntitlement
```

`ProEntitlementTests` is a separate SwiftPM test target. Automatic PR CI retains
its existing lint and policy assertions. These tests cover verified and
unverified purchases, trial and grace, revocations, offline boundaries, stale
events, failed cache writes, publication before finish, restore intent and cache
contents. They use synthetic values and do not contact the App Store.

## Local StoreKit products

[StoreKit/CodexBarPro.storekit](StoreKit/CodexBarPro.storekit) defines monthly
US$1.99, yearly US$14.99 and lifetime US$29.99 products. Monthly and yearly share
level 1 of the CodexBar Pro group. Only yearly offers a one-week free trial.
Family Sharing is disabled. These values are local test fixtures, not proof of
App Store Connect configuration or permission to charge.

To exercise StoreKit in Xcode, duplicate the app's scheme for local use and
select this file under Run > Options > StoreKit Configuration. Keep the shared
production scheme unchanged. Follow Apple's
[StoreKit testing setup](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
for simulated purchases, refunds and renewal failures. The configuration is not
an app-bundle resource and is never selected by an archive.

## Verification and storage

The service starts transaction and subscription-status listeners before its
launch snapshot, then refreshes on foreground entry. A generation check prevents
a suspended snapshot from overwriting a newer event. Signed transaction dates
and identifiers order events in memory; neither is logged. Revocations can also
be recovered through StoreKit's latest signed record after an app restart.

The App Group cache contains the winning reason, expiry, access deadline,
verification time, purchase date, environment and the known subscription product. It contains no transaction
ID, Apple Account identifier, signed token or provider data. A successful atomic
cache write and publication precede finishing a verified purchase or update.
Failed writes and unverified purchases remain unfinished.

Production, sandbox and Xcode decisions use separate cache files. Only a
production-verified decision may bootstrap access before StoreKit confirms the
current environment. Test purchases cannot become permanent production access,
and test sessions do not overwrite the production cache. The saved purchase date
prevents an older refund from erasing a newer repurchase after relaunch.

Offline subscription access ends exactly three days after the last verified
paid or grace expiry. A cached status aging past that date does not invent a new
verification or move the deadline. Explicit verified expiry, retry without grace
or revocation overrides the allowance for the affected purchase. Independent
permanent grants survive subscription loss. With no verified cache, startup is
free. A timer expires access locally before waiting for StoreKit. Foreground
refresh re-evaluates the complete decision without a relaunch.

The developer override exists only under `#if DEBUG`, never writes the verified
cache, and is absent from Release builds. Live App Store configuration, sandbox
purchase UI and production original-purchaser checks belong to their dependent
issues; no such check is claimed by the injected tests.
