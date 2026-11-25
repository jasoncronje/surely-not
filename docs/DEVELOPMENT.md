# Building Surely Not

Notes for developers. For what the app is, see the [README](../README.md).

Requires Xcode 26 or later and iOS 26 or later. There are no third-party dependencies.

Open `SurelyNot.xcodeproj` and run the `SurelyNot` scheme.

## TestFlight

The app is in App Store Connect as "Surely Not" (app ID `6839306865`). `scripts/testflight.sh` archives a Release build, signs it for App Store Connect and uploads it. It needs Xcode signed in to the team and the `asc` CLI signed in with an App Store Connect API key. The build number is the current UTC time, so each upload is higher than the last. The "Internal Testers" group gets every build; external testers would need Apple's beta review first.

Whatever `Config/Local.xcconfig` says goes into the build, so on a Mac with Wallet sync on, TestFlight builds carry FinanceKit too.

## Apple Wallet

Apple has no server API for Apple Card. The only way to read it is on the phone, through Apple's FinanceKit. So the app reads Wallet and uploads what changed to Sure's Wallet API (`/api/v1/financekit`), which Sure already has.

What it needs:

- **Apple's permission.** FinanceKit only works in an app with the `com.apple.developer.financekit` entitlement, and stops the app dead if it is called without it. Apple grants the entitlement on request, per app; the Account Holder has to ask ([Get started with FinanceKit](https://developer.apple.com/financekit)). Apple granted it for `io.cronje.surelynot` on 25 November 2026, to an individual account, before the app was on the App Store. After the grant, tick FinanceKit on the App ID in Certificates, Identifiers & Profiles (FinanceKit Transaction Picker UI is not needed). Until Apple has granted it, leave Wallet sync off: a build signed with the entitlement before then will not install on a phone.
- **A real iPhone** in a country where Wallet shares account data: the United States for Apple Card, Apple Cash and Savings, and the United Kingdom for connected bank accounts. The Simulator has no Wallet data.
- **A current Sure server, reached over `https://`.** Wallet data is never sent over plain `http://`, not even on a local network.
- **A sign-in with a second step**, by an administrator of the household: email, password and a two-factor code, or single sign-on. A password alone or an API key will not do. Apple's FinanceKit terms ask for both of these, so the app holds itself to them.

To look at the Wallet screens in the Simulator, which has no Wallet data, run a Debug build with the launch argument `-WalletDemo setup` (the connect sheet) or `-WalletDemo connected` (a live connection). Both use a pretend Wallet and a pretend Sure, and are left out of Release builds.

To turn it on once Apple has granted the entitlement, create `Config/Local.xcconfig` (git ignores it) with:

```
WALLET_SYNC_ENABLED = YES
```

The entitlements follow from that line, so no `CODE_SIGN_ENTITLEMENTS` line is needed (an older one is ignored). Without the file the app builds and runs as before, and the Apple Wallet screen says the build has no permission.

### Background sync

The app can also sync Wallet while it is closed. iOS 26 wakes a small extension in the app, `SurelyNotWalletSync`, when Wallet has something new, at most about once an hour, and the extension sends it to Sure the same way the app does. It is off until you turn it on, because it needs a second grant from Apple:

- **FinanceKit for the extension.** The extension has its own App ID, `io.cronje.surelynot.walletsync`, and Apple grants FinanceKit per App ID. Ask for it the same way as for the app, then tick FinanceKit on that App ID too. Until then leave background sync off: a build that embeds the extension signed with FinanceKit will not install.
- **The App Group `group.io.cronje.surelynot`** on both App IDs, so the app and the extension share the Wallet state. Register it under Identifiers and add it to both App IDs, or let Xcode's automatic signing do that the first time it signs a build with background sync on.

Then add a second line to `Config/Local.xcconfig`:

```
WALLET_SYNC_ENABLED = YES
WALLET_BACKGROUND_ENABLED = YES
```

With it off, the build is the same as before: the extension is compiled but not signed and not put in the app, the app's entitlements do not change, and the app never asks iOS for background delivery. The Wallet screen says "Background sync is off".

With it on:

- Once Wallet is connected, the app asks iOS to wake the extension for new accounts, balances and transactions, hourly at most. Disconnecting asks iOS to stop.
- The first launch moves the Wallet state (the connection, where each account's history was read up to, and any uploads still waiting) from the app's own folder into the shared one. It copies, checks the copy byte for byte, puts it in place in one step, then removes the original, so the live connection carries on where it was. If the move cannot finish, the app keeps using its own folder and tries again next launch.
- The app and the extension take a shared lock before touching the Wallet state, and read it afresh once they have it, so they never read Wallet or upload at the same time. A sync that finds the lock taken skips quietly; the other side has it covered.
- The extension holds to the same rules as the app: nothing is sent unless someone is signed in, with a second step, to a server on `https://`. It never asks for Wallet access and shows nothing.
- The extension uploads with the connection's upload key only, and never uses your sign-in, so it cannot sign you out by refreshing a token at the same moment as the app. Anything that needs the sign-in, such as a new upload key or a repair, waits for the app to open.
- The sign-in and the upload key stay where they are in the Keychain. The extension reads them from the app's own keychain group; the widget, which shares a different group, never sees them.

How it behaves:

- You pick the Wallet accounts in Apple's own sheet, then choose for each one whether Sure makes a new account or it goes into an existing account of the same kind and currency.
- It syncs when you open the app and when you tap Sync now, and with background sync on, while the app is closed.
- The first sync sends everything Wallet has, or only recent or new activity if you choose that. After that it sends only what changed, including transactions Wallet removed.
- Uploads are written to disk first and sent in order, so a lost connection loses nothing and nothing is sent twice.
- Sure does not overwrite a transaction you edited in Sure. It holds the change back and the app lists it under "needs a look".
- If Sure and the phone fall out of step, the app says so and offers a repair, which sends Wallet again in full. Sure matches what it already has.
- Disconnecting keeps what was imported, or removes it if you ask.

The code is in `SurelyNot/Wallet`, and the extension's entry point in `SurelyNotWalletSync`. `FinanceKitSource.swift` and the extension's `WalletSyncExtension.swift` are the only files that touch FinanceKit; the rest is tested against a pretend Wallet and a pretend Sure in `SurelyNotTests/WalletTests.swift` and `SurelyNotTests/WalletBackgroundTests.swift`.

## Design

The look is defined in `SurelyNot/Support/Theme.swift` and the shared pieces in `SurelyNot/Support/Components.swift`. The rules: colour belongs on data, not on buttons and bars; one blue marks the main thing a screen is about; categories and institutions get a pale tint of their own colour; surfaces are flat with one large corner radius; red is kept for what is over or wrong.

The typeface is [Manrope](https://github.com/sharanda/manrope), bundled in `SurelyNot/Fonts` under the SIL Open Font License (see `OFL.txt` there).

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding, removing or moving files, run `xcodegen generate` and commit the result.

