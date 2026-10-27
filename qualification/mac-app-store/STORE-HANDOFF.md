# Mac App Store hand-off for Franz

Prepared October 27, 2026 for [#476](https://github.com/hemsoft-dev/codexbar-ios/issues/476).
Agents stop at the end of local qualification. Every step below needs Franz's
Apple account, App Store Connect, pricing, submission or publication authority,
so no agent has performed any of them. Nothing here selects the shipping
channel or promises cross-platform Pro; [#475](https://github.com/hemsoft-dev/codexbar-ios/issues/475)
still owns the billing decision.

## What is already qualified locally

See [RESULTS.md](RESULTS.md). In short:

- A universal arm64 + x86_64 bundle targets macOS 14.
- The sandboxed self-test passes natively and under Rosetta 2.
- Guided loopback authorization, account-isolated Keychain credentials, the
  Dashboard/Settings window, native StoreKitTest restore/refund (Xcode 26.6) and
  a local replacement/rollback rehearsal all pass.
- The team's existing Apple Development and Apple Distribution identities sign
  the bundle with the sandbox entitlements and pass strict verification.

## Franz-owned steps, in order

1. **Choose the channel.** Confirm the native Mac App Store as the first
   desktop channel, or pick Windows/Linux from #459. This is the remaining
   selected-channel criterion.
2. **Decide universal purchase before touching the record.** A universal
   purchase needs the macOS app on the **existing** CodexBar app record with the
   **same bundle ID** as iOS. Separate records cannot be merged later, and
   removing an approved platform is constrained ([Apple: add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms)).
   The iOS record currently keeps its Mac availability setting from 1.4.0.
   Confirm in App Store Connect how adding a native macOS platform interacts
   with that setting before adding it.
3. **Enable macOS for the existing App ID** in Certificates, Identifiers &
   Profiles, with App Sandbox, outgoing and incoming network, and the Keychain
   access group the shipping app will use.
4. **Create a Mac App Store provisioning profile** for that App ID with the
   existing Apple Distribution certificate. That certificate is unrevoked in
   the CodexBar signing keychain and valid until October 7, 2027.
5. **Create a Mac Installer Distribution certificate** ("3rd Party Mac
   Developer Installer"). None exists in the CodexBar signing keychain, and the
   Store upload package (`productbuild --sign`) needs it.
6. **Add the macOS platform version, pricing and availability** in App Store
   Connect. Production checkout stays off until #475 is decided.
7. **Upload a TestFlight build for macOS** and install it on a Mac through
   TestFlight. This is the first real Store-signed install. It also starts the
   checks that remain NOT RUN: Store update, receipt preservation and
   cross-update Keychain access.
8. **Verify restore with a real Apple account.** Check that the lifetime
   product restores on macOS. Separately check whether an original paid iOS
   purchaser is recognized; the prototype makes no such claim.
9. **Submit for review and release.** Publication is Franz's call.

## Container identity rule found during qualification

On air, launching a build signed by a different identity under a bundle ID
whose sandbox container already existed blocked during sandbox initialization
before any app code ran. Later launches of that bundle ID blocked as well,
including the original ad hoc build. The same Development-signed bundle under a
fresh bundle ID passed. The blocking decision was not visible to the agent;
it is most likely a pending system container-ownership prompt on air's screen.

For the shipping app this means:

- Sign every build of the shipping bundle ID with the one Apple team.
- Never run ad hoc or other-team builds under the shipping ID on a tester's Mac.
- Keep `com.hemsoft.qualification.mac476` and its suffixes separate from
  production.

If air's screen shows a prompt about the qualification app accessing another
app's data, answering it unblocks further runs of that qualification bundle ID.
It has no effect on production apps.
