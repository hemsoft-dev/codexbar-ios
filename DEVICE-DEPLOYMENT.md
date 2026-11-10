# Connected iPhone Deployment and Signing

This runbook contains the detailed operational guidance extracted from
`AGENTS.md`. Use Xcode explicitly because the active `xcode-select` path may
point at Command Line Tools. Device IDs, DerivedData paths, provisioning-profile
UUIDs, and certificate fingerprints change over time; discover them during each
run instead of copying a recorded value.

## Build, Install, Launch, and Verify

1. List connected devices and copy the current iPhone identifier:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcrun devicectl list devices
   ```

2. Build through the temporary signing-keychain wrapper:

   ```sh
   ./scripts/with-codexbar-keychain.sh env \
     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild \
       -allowProvisioningUpdates \
       -allowProvisioningDeviceRegistration \
       -project CodexBarIOS.xcodeproj \
       -scheme CodexBarIOS \
       -destination 'id=<DEVICE_ID>' \
       build
   ```

3. Resolve the current device build-products directory instead of reusing a
   recorded DerivedData path:

   ```sh
   BUILD_PRODUCTS_DIR="$(
     ./scripts/with-codexbar-keychain.sh env \
       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
       xcodebuild \
         -project CodexBarIOS.xcodeproj \
         -scheme CodexBarIOS \
         -destination 'id=<DEVICE_ID>' \
         -showBuildSettings |
       awk -F'= ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}'
   )"
   ```

4. Install and launch:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcrun devicectl device install app \
       --device <DEVICE_ID> \
       "$BUILD_PRODUCTS_DIR/CodexBarIOS.app"

   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcrun devicectl device process launch \
       --device <DEVICE_ID> \
       com.hemsoft.CodexBarIOS
   ```

5. Verify the process:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcrun devicectl device info processes \
       --device <DEVICE_ID> |
     rg -n 'CodexBar|com\.hemsoft' -C 2
   ```

   Substitute `grep` if ripgrep is unavailable. If remote launch fails because
   the phone is locked, installation may still have succeeded; ask the user to
   unlock the phone or open the app manually.

## Dedicated Signing Keychain

Use the dedicated CodexBar signing keychain, not the login keychain:

```text
~/Library/Keychains/codexbar-dev.keychain-db
```

The user chose its password through a hidden macOS prompt. Never ask for, print,
or store that password in chat or repository files. Its owner-only local file
is outside the login keychain:

```text
~/Library/Application Support/CodexBar/signing-keychain-password
mode: 600
```

Do not move the password into a login-keychain generic-password item. The normal
search list must not contain `codexbar-dev.keychain-db`, which locks on sleep
and can otherwise cause unrelated services to prompt for its password.
`login.keychain-db` must remain the default keychain.

Unlock and verify without adding the dedicated keychain to the global search
list:

```sh
./scripts/unlock-codexbar-keychain.sh
security list-keychains -d user
security default-keychain
security find-identity -v -p codesigning \
  "$HOME/Library/Keychains/codexbar-dev.keychain-db" |
  grep -F '"Apple Development:'
```

The live output, not a fingerprint copied from an earlier run, determines the
current signing identity. The expected state is:

- `codexbar-dev.keychain-db` is absent from the normal search list.
- `login.keychain-db` is the default.
- The dedicated keychain reports at least one live Apple Development identity
  for automatic device signing. Select the identity from this live output;
  multiple valid development identities alone do not require deletion or a
  keychain reset.

All device builds must run through `scripts/with-codexbar-keychain.sh`. It adds
the dedicated keychain to the search list only for the wrapped command and
restores the normal list on success, failure, or interruption.

## Recovery

After a reboot or lock, first run:

```sh
./scripts/unlock-codexbar-keychain.sh
```

If the dedicated keychain or owner-only password file is missing or unusable,
run:

```sh
./scripts/reset-codexbar-keychain.sh
```

The reset helper asks for a new password twice through hidden local dialogs and
backs up the previous signing keychain before recreating it. A newly reset
keychain has no signing identity, so run the trap-protected provisioning build
below after every successful reset.

If Xcode reports that an existing development certificate has no private key,
revoke only that stale Apple Development certificate in the developer portal
before running the build. Certificate revocation is conditional on that error;
the provisioning build is required after every reset. It makes the dedicated
keychain the default only while Xcode provisions its replacement identity:

```sh
./scripts/with-codexbar-keychain.sh /bin/bash -c '
  set -euo pipefail
  LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"
  restore_default() {
    security default-keychain -d user -s "$LOGIN_KEYCHAIN"
  }
  trap restore_default EXIT
  trap "exit 129" HUP
  trap "exit 130" INT
  trap "exit 143" TERM
  security default-keychain -d user -s "$SIGNING_KEYCHAIN"
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      -project CodexBarIOS.xcodeproj \
      -scheme CodexBarIOS \
      -destination "id=<DEVICE_ID>" \
      build
'
```

The inner trap and outer wrapper both restore `login.keychain-db` as the default
after success, failure, or interruption. Do not keep deleting identities or
generating certificates.

If the dedicated keychain is ever left in the global search list, restore the
normal state:

```sh
security list-keychains -d user -s \
  "$HOME/Library/Keychains/login.keychain-db" \
  /Library/Keychains/System.keychain
security default-keychain -d user -s \
  "$HOME/Library/Keychains/login.keychain-db"
```

## Why These Rules Exist

Historical login-keychain identity duplication made Xcode signing selection
nondeterministic and caused repeated `CodeSign` hangs. Leaving the lock-on-sleep
dedicated keychain in the global search list also caused unrelated macOS
services to prompt for its password. These incidents are the reason to isolate
the dedicated keychain, reset and reprovision it when it is unusable, discover
live identifiers and identities, and avoid using old snapshots as current
configuration. Do not fall back to signing from the login keychain.
