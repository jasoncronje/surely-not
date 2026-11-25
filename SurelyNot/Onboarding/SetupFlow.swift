import SwiftUI

/// Shown once after a fresh sign-in: the optional extras that otherwise sit
/// in Settings, then a short "you're in" while the first numbers arrive.
struct SetupFlow: View {
    let client: APIClient

    @Environment(Session.self) private var session
    @State private var step = Step.extras

    private enum Step { case extras, ready }

    var body: some View {
        ZStack {
            switch step {
            case .extras:
                SetupExtrasView { withAnimation(.smooth(duration: 0.4)) { step = .ready } }
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(x: -24))))
            case .ready:
                SetupReadyView(client: client) { session.offersSetup = false }
                    .transition(.opacity.combined(with: .offset(x: 24)))
            }
        }
        .screenBackground()
    }
}

/// Face ID and bill reminders, each one switch with a line of why. iOS only
/// asks for permission when a switch is turned on, so nothing pops up uninvited.
private struct SetupExtrasView: View {
    let done: () -> Void

    @Environment(AppLock.self) private var lock
    @State private var remindersOn = BillReminders.isEnabled
    @State private var remindersRefused = false

    private var lockIsOn: Binding<Bool> {
        Binding(get: { lock.isEnabled }, set: { wanted in
            Task { await lock.setEnabled(wanted) }
        })
    }

    private var remindersBinding: Binding<Bool> {
        Binding(get: { remindersOn }, set: { wanted in
            remindersOn = wanted
            Task {
                if wanted {
                    if !(await BillReminders.enable()) {
                        remindersOn = false
                        remindersRefused = true
                    }
                } else {
                    await BillReminders.disable()
                }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make it yours")
                            .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(Theme.text)
                        Text("Both are optional. You can change them any time in Settings.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)

                    Card {
                        ExtraToggle(
                            isOn: lockIsOn,
                            systemImage: lock.methodName == "Face ID" ? "faceid" : "lock",
                            title: "Lock with \(lock.methodName)",
                            detail: "Asks when you open the app, and hides your figures in the app switcher."
                        )
                        RowRule()
                        ExtraToggle(
                            isOn: remindersBinding,
                            systemImage: "bell",
                            title: "Bill reminders",
                            detail: "A notification at 9 in the morning, the day before each bill."
                        )
                    }

                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            ExtraIcon(systemImage: "square.grid.2x2")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add the widget")
                                    .font(Theme.bodyStrong)
                                    .foregroundStyle(Theme.text)
                                Text("Touch and hold your Home Screen, tap Edit, then Add Widget and pick Surely Not.")
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .screenColumn(margin: 24, maxWidth: Theme.formWidth)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }

            Button("Continue", action: done)
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .screenColumn(margin: 24, maxWidth: Theme.formWidth)
                .padding(.bottom, 8)
        }
        .sensoryFeedback(.selection, trigger: remindersOn)
        .sensoryFeedback(.selection, trigger: lock.isEnabled)
        .alert("Notifications are off", isPresented: $remindersRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications for Surely Not in the Settings app, then turn reminders on in Settings.")
        }
        .alert("The lock was not changed", isPresented: Binding(
            get: { !(lock.error ?? "").isEmpty },
            set: { if !$0 { lock.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lock.error ?? "")
        }
    }
}

private struct ExtraIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: 40)
            .background(Theme.raised, in: .rect(cornerRadius: Theme.tileRadius))
            .accessibilityHidden(true)
    }
}

private struct ExtraToggle: View {
    @Binding var isOn: Bool
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 14) {
                ExtraIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.accent)
    }
}

/// "You're in", with the first real numbers counting in as they load, so
/// the first sync reads as progress rather than a spinner.
private struct SetupReadyView: View {
    let client: APIClient
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accounts: Int?
    @State private var bills: Int?
    @State private var transactions: Int?
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Theme.positive)
                        .frame(width: 72, height: 72)
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: shown)
                }
                .scaleEffect(shown ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
                VStack(spacing: 8) {
                    Text("You're in")
                        .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(Theme.text)
                    Text("Here's what came over from your server.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 32)

            Card {
                CountRow(title: "Accounts", value: accounts)
                RowRule()
                CountRow(title: "Bills tracked", value: bills)
                RowRule()
                CountRow(title: "Transactions this month", value: transactions)
            }
            Spacer()
            Button("Open Home", action: done)
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
        }
        .screenColumn(margin: 24, maxWidth: Theme.formWidth)
        .padding(.bottom, 8)
        .sensoryFeedback(.success, trigger: shown)
        .task {
            withAnimation(reduceMotion ? .none : .spring(duration: 0.5, bounce: 0.35)) { shown = true }
            await load()
        }
    }

    /// Each count lands as soon as its own request answers. A failure just
    /// leaves that row blank; Home will say what went wrong.
    private func load() async {
        async let first: Void = loadAccounts()
        async let second: Void = loadBills()
        async let third: Void = loadTransactions()
        _ = await (first, second, third)
    }

    private func loadAccounts() async {
        let value = try? await client.accounts().count
        withAnimation(.smooth) { accounts = value ?? 0 }
    }

    private func loadBills() async {
        let value = try? await client.bills().filter(\.isActive).count
        withAnimation(.smooth) { bills = value ?? 0 }
    }

    private func loadTransactions() async {
        let page = try? await client.transactions(matching: TransactionFilter(period: .thisMonth), page: 1, perPage: 1)
        withAnimation(.smooth) { transactions = page?.pagination?.totalCount ?? page?.items.count ?? 0 }
    }
}

private struct CountRow: View {
    let title: String
    let value: Int?

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
            Spacer()
            if let value {
                Text(value, format: .number)
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(value)))
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
