# Privacy policy

Surely Not is an app for your own [Sure](https://github.com/we-promise/sure) server. This is what it does with your data.

Last updated 24 November 2026.

## In short

The app talks to one server: the Sure server whose address you enter. It sends your data nowhere else. The developer of Surely Not never receives your data and has no server for it to go to.

## What the app handles

- **Your Sure data.** Accounts, balances, transactions, budgets, bills and chats are fetched from your Sure server to show them to you, and changes you make are sent back to that server. They are held in memory while the app is open.
- **Your sign-in.** The server address and the API key or sign-in tokens are kept in the iOS Keychain on your device. Your password is sent to your Sure server to sign in and is not kept.
- **A device ID.** The app makes a random ID for this install and sends it to your Sure server, which uses it to tie your sign-in to this device.
- **Face ID.** If you turn the lock on, iOS checks your face or passcode. The app only learns whether the check passed.

## Apple Wallet

Wallet sync is off unless you connect it. If you do:

- Apple shows its own sheet where you choose which Wallet accounts to share with the app. You can change or withdraw that in the Settings app at any time.
- The app reads the accounts you chose, their balances and their transactions from Wallet on your device, using Apple's FinanceKit.
- It sends them to your Sure server and nowhere else, and only over an encrypted (`https://`) connection. Everyone in your Sure household can then see them there.
- Wallet sync only works if you signed in with a second step: a two-factor code or single sign-on.
- Uploads waiting to be sent are kept in the app's own storage on your device, left out of device backups, and deleted once your server has taken them.
- The key that lets the app upload is kept in the iOS Keychain. It can add Wallet data to your one connection and cannot read anything from Sure.
- Disconnecting stops the uploads. You can keep what was imported in Sure or have Sure remove it.

Wallet data is used only to show your own finances in your own Sure. It is not used for advertising, not sold, and not shared with anyone.

## What the app does not do

- No analytics, no advertising, no tracking, and no crash reporting to the developer.
- No third-party services or software kits.
- No account with the developer.

## Your Sure server

What happens to data once it is on your Sure server is up to whoever runs that server. If it uses an AI provider for chat, for example, that is set up on the server and not in this app.

## Deleting your data

Signing out removes your sign-in from the device. Deleting the app removes everything it stored, apart from Keychain entries, which iOS may keep; signing out or disconnecting Wallet first removes those. Data on your Sure server is deleted in Sure.

## Contact

Questions about this policy: open an issue at https://github.com/jasoncronje/surely-not/issues.
