# Surely Not

Surely Not is an unofficial, community-built native iOS client (Swift / SwiftUI) for self-hosted [Sure](https://github.com/we-promise/sure), the open source personal finance app.

## Status

Early, version 0.1. It builds and its unit tests pass, but it has not been released.

## What it does

Four tabs, each backed by Sure's REST API (`/api/v1`):

- **Overview**: net worth, this month's income and spending, spending compared with normal, the latest transactions, and insights. Tap a category to see the transactions behind it.
- **Bills**: this month's confirmed repeating payments, what is still to pay, and what has been paid. The app finds each payment in your transactions itself, because Sure's own record of the last payment can lag. Reached from Overview. Repeating payments Sure has only suggested can be tracked with one tap, and a tracked bill can be stopped.
- **Transactions**: every transaction across your accounts, with search and filters for period, type, account and category. Add one with the plus button. Move one to another category by tapping its category, or by pressing and holding its row. A list filtered to one category shows that category's last six months as a chart. Each one opens a detail screen with its notes, tags and links to everything else at that merchant, in that category or in that account.
- **Chat**: Sure's AI assistant. Start, rename and delete chats, send messages, retry failed replies.
- **Budgets**: each month's budget with spending per category. Tap a category to see that month's transactions in it.
- **Investments**: every position across your investment accounts, each one's share of the total, and how the total and each position have moved over the last 90 days. Reached from Accounts.
- **Widget**: a home screen and lock screen widget with what is still to pay this month, the next bills due, and spending against the month's budget. It shows what the app last loaded; iOS wakes the app in the background now and then to refresh it. Amounts are hidden while the phone is locked.
- **Bill reminders**: an optional notification at 9 in the morning the day before each bill, switched on in Settings. They are local to the phone and are dropped once a bill is paid.
- **Lock**: an optional Face ID, Touch ID or passcode lock, switched on in Settings. It asks on opening and after a minute away, and hides the figures in the app switcher.
- **Accounts**: accounts grouped by type, 90-day balance history, holdings, and transactions you can add, edit and delete.
- **Apple Wallet**: sends Apple Card, Apple Cash and Savings from Wallet on your phone to Sure, with balances and transactions. Reached from Accounts. See [Apple Wallet](#apple-wallet) for what it needs.

Enter your server address, then sign in the way that server allows: single sign-on (Pocket ID, Google and so on), email and password (with a two-factor code if you use one), or an API key. Sign-in details are stored only in the iOS Keychain.

### Known limits

These come from what Sure's API offers:

- Budgets and accounts are read-only, apart from accounts that Apple Wallet sync adds. Create and change the rest in Sure on the web.
- Apple Wallet sync has not been run against a real Apple Card yet. It is tested against Sure's own rules for uploads, not against Wallet itself.
- Chat replies are not streamed. The app checks for the reply every two seconds.
- Only the first 50 messages of a very long chat are shown.
- Single sign-on cannot link a new account or sign in an account that uses a two-factor code. Link the account in a browser first, or use email and password.
- Plain `http://` works only for servers on your local network. Anything else needs `https://`.

## Building

Requires Xcode 26 or later and iOS 26 or later. There are no third-party dependencies.

Open `SurelyNot.xcodeproj` and run the `SurelyNot` scheme.

### Apple Wallet

Apple has no server API for Apple Card. The only way to read it is on the phone, through Apple's FinanceKit. So the app reads Wallet and uploads what changed to Sure's Wallet API (`/api/v1/financekit`), which Sure already has.

What it needs:

- **Apple's permission.** FinanceKit only works in an app with the `com.apple.developer.financekit` entitlement, and stops the app dead if it is called without it. Apple grants the entitlement on request, per app; the Account Holder has to ask ([Get started with FinanceKit](https://developer.apple.com/financekit)). Apple granted it for `io.cronje.surelynot` on 25 November 2026, to an individual account, before the app was on the App Store. After the grant, tick FinanceKit on the App ID in Certificates, Identifiers & Profiles (FinanceKit Transaction Picker UI is not needed). Until Apple has granted it, leave Wallet sync off: a build signed with the entitlement before then will not install on a phone.
- **A real iPhone** in a country where Wallet shares account data: the United States for Apple Card, Apple Cash and Savings, and the United Kingdom for connected bank accounts. The Simulator has no Wallet data.
- **A current Sure server, reached over `https://`.** Wallet data is never sent over plain `http://`, not even on a local network.
- **A sign-in with a second step**, by an administrator of the household: email, password and a two-factor code, or single sign-on. A password alone or an API key will not do. Apple's FinanceKit terms ask for both of these, so the app holds itself to them.

To turn it on once Apple has granted the entitlement, create `Config/Local.xcconfig` (git ignores it) with:

```
WALLET_SYNC_ENABLED = YES
CODE_SIGN_ENTITLEMENTS = SurelyNot/Wallet.entitlements
```

Without that file the app builds and runs as before, and the Apple Wallet screen says the build has no permission.

How it behaves:

- You pick the Wallet accounts in Apple's own sheet, then choose for each one whether Sure makes a new account or it goes into an existing account of the same kind and currency.
- It syncs when you open the app and when you tap Sync now. It does not sync while the app is closed.
- The first sync sends everything Wallet has, or only recent or new activity if you choose that. After that it sends only what changed, including transactions Wallet removed.
- Uploads are written to disk first and sent in order, so a lost connection loses nothing and nothing is sent twice.
- Sure does not overwrite a transaction you edited in Sure. It holds the change back and the app lists it under "needs a look".
- If Sure and the phone fall out of step, the app says so and offers a repair, which sends Wallet again in full. Sure matches what it already has.
- Disconnecting keeps what was imported, or removes it if you ask.

The code is in `SurelyNot/Wallet`. `FinanceKitSource.swift` is the only file that touches FinanceKit; the rest is tested against a pretend Wallet and a pretend Sure in `SurelyNotTests/WalletTests.swift`.

### Design

The look is defined in `SurelyNot/Support/Theme.swift` and the shared pieces in `SurelyNot/Support/Components.swift`. The rules: colour belongs on data, not on buttons and bars; one blue marks the main thing a screen is about; categories and institutions get a pale tint of their own colour; surfaces are flat with one large corner radius; red is kept for what is over or wrong.

The typeface is [Manrope](https://github.com/sharanda/manrope), bundled in `SurelyNot/Fonts` under the SIL Open Font License (see `OFL.txt` there).

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding, removing or moving files, run `xcodegen generate` and commit the result.

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by the Sure project, its maintainers, or Maybe Finance. "Sure" and "Maybe" are names of their respective owners and are used here only to describe what this client connects to.

## Licence

Licensed under the [MIT License](LICENSE).

Sure itself is licensed under AGPL-3.0. This client contains no Sure code or assets; it only talks to a Sure server through its API.
