# Surely Not

Surely Not is an unofficial, community-built native iOS client (Swift / SwiftUI) for self-hosted [Sure](https://github.com/we-promise/sure), the open source personal finance app.

## Status

Early, version 0.1. It builds and its unit tests pass, but it has not been released.

## What it does

Four tabs, each backed by Sure's REST API (`/api/v1`):

- **Overview**: net worth, this month's income and spending, spending compared with normal, and insights.
- **Chat**: Sure's AI assistant. Start, rename and delete chats, send messages, retry failed replies.
- **Budgets**: each month's budget with spending per category.
- **Accounts**: accounts grouped by type, 90-day balance history, holdings, and transactions you can add, edit and delete.

Sign in with your server address and either email and password (with a two-factor code if you use one) or an API key. Sign-in details are stored only in the iOS Keychain.

### Known limits

These come from what Sure's API offers:

- Budgets and accounts are read-only. Create and change them in Sure on the web.
- Chat replies are not streamed. The app checks for the reply every two seconds.
- Only the first 50 messages of a very long chat are shown.
- Single sign-on (SSO) is not supported yet. Use an API key if your server is SSO-only.
- Plain `http://` works only for servers on your local network. Anything else needs `https://`.

## Building

Requires Xcode 26 or later and iOS 26 or later. There are no third-party dependencies.

Open `SurelyNot.xcodeproj` and run the `SurelyNot` scheme.

### Design

The look is defined in `SurelyNot/Support/Theme.swift` and the shared pieces in `SurelyNot/Support/Components.swift`. The rules: colour belongs on data, not on buttons and bars; one blue marks the main thing a screen is about; categories and institutions get a pale tint of their own colour; surfaces are flat with one large corner radius; red is kept for what is over or wrong.

The typeface is [Manrope](https://github.com/sharanda/manrope), bundled in `SurelyNot/Fonts` under the SIL Open Font License (see `OFL.txt` there).

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding, removing or moving files, run `xcodegen generate` and commit the result.

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by the Sure project, its maintainers, or Maybe Finance. "Sure" and "Maybe" are names of their respective owners and are used here only to describe what this client connects to.

## Licence

Licensed under the [MIT License](LICENSE).

Sure itself is licensed under AGPL-3.0. This client contains no Sure code or assets; it only talks to a Sure server through its API.
