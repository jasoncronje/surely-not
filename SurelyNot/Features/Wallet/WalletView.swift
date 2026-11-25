import SwiftUI

/// Apple Wallet sync: what it is, whether it is connected, and how it is doing.
struct WalletView: View {
    let client: APIClient
    @Environment(WalletSync.self) private var wallet
    @State private var isSettingUp = false
    @State private var isConfirmingDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                switch wallet.availability {
                case .checking:
                    Card { LoadingLines() }
                case .unavailable(let why):
                    Card(title: "Not available here") {
                        Text(why)
                            .font(Theme.body)
                            .foregroundStyle(Theme.muted)
                        Button("Check again") {
                            Task { await wallet.refresh() }
                        }
                        .font(Theme.smallStrong)
                        .foregroundStyle(Theme.text)
                    }
                    // A connection made earlier can still be closed.
                    if wallet.isConnected {
                        disconnectButton
                    }
                case .ready:
                    if let link = wallet.link {
                        connected(link)
                    } else {
                        introduction
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Apple Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task { await wallet.refresh() }
        .refreshable { await wallet.refresh() }
        .sheet(isPresented: $isSettingUp) {
            WalletSetupView(client: client)
        }
        .confirmationDialog(
            "Disconnect Apple Wallet?",
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect and keep what was imported") {
                Task { await wallet.disconnect(removingImported: false) }
            }
            if wallet.serverCanDiscard {
                Button("Disconnect and remove what was imported", role: .destructive) {
                    Task { await wallet.disconnect(removingImported: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sure stops getting new Wallet activity. Removing what was imported cannot be undone.")
        }
    }

    private var introduction: some View {
        Group {
            Card(title: "Bring Wallet into Sure") {
                Text("Apple Card, Apple Cash and Savings can show up in Sure with their balances and transactions. This phone reads them from Wallet and sends them to your Sure server\(host.map { " at \($0)" } ?? ""). They go nowhere else.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
                Button("Connect Apple Wallet") {
                    wallet.clearProblem()
                    isSettingUp = true
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(wallet.isWorking)
            }
            problemNote
        }
    }

    private var host: String? { client.baseURL.host() }

    @ViewBuilder
    private func connected(_ link: WalletLink) -> some View {
        Card {
            VStack(spacing: 14) {
                ForEach(link.accounts) { account in
                    HStack(spacing: 12) {
                        LetterTile(name: account.name, tint: Tint(name: account.name), round: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(Theme.body)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(account.reportedUnavailable ? "No longer shared from Wallet"
                                : account.isLiability ? "Credit card" : "Cash")
                                .font(Theme.small)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            RowRule()
            FigureRow(label: "Last synced", value: lastSynced(link))
            if !link.outbox.isEmpty {
                FigureRow(
                    label: "Waiting to upload",
                    value: "\(link.outbox.count) \(link.outbox.count == 1 ? "batch" : "batches")"
                )
            }
            if wallet.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(wallet.activity ?? "Working")
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            } else if wallet.repairNeeded == nil {
                Button("Sync now") {
                    Task { await wallet.sync() }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
            if let outcome = wallet.lastOutcome, !wallet.isWorking {
                Text(outcome)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
        }

        if let why = wallet.repairNeeded {
            Card(title: "Needs a repair") {
                Text("\(why) A repair sends everything from Wallet again. Sure matches what it already has, so nothing is doubled.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
                Button("Repair and send again") {
                    Task { await wallet.repair() }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(wallet.isWorking)
            }
        } else {
            problemNote
        }

        if wallet.openConflicts > 0 {
            NavigationLink {
                WalletReviewView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(wallet.openConflicts) \(wallet.openConflicts == 1 ? "record needs" : "records need") a look")
                            .font(Theme.bodyStrong)
                            .foregroundStyle(Theme.text)
                        Text("Sure held back changes that would undo edits made in Sure.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            }
            .buttonStyle(.plain)
        }

        Text("Wallet syncs when you open the app and when you tap Sync now. It does not sync while the app is closed.")
            .font(Theme.small)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 4)

        disconnectButton
    }

    private var disconnectButton: some View {
        Button("Disconnect Apple Wallet") {
            isConfirmingDisconnect = true
        }
        .font(Theme.bodyStrong)
        .foregroundStyle(Theme.negative)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(wallet.isWorking)
    }

    @ViewBuilder
    private var problemNote: some View {
        if let problem = wallet.problem, !wallet.isWorking {
            Text(problem)
                .font(Theme.small)
                .foregroundStyle(Theme.negative)
                .padding(.horizontal, 4)
        }
    }

    private func lastSynced(_ link: WalletLink) -> String {
        guard let date = link.lastSyncedAt else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// The way in to Wallet sync from the Accounts screen.
struct WalletEntryRow: View {
    @Environment(WalletSync.self) private var wallet

    private var status: String {
        guard let link = wallet.link else { return "Bring Apple Card and Apple Cash into Sure" }
        if link.repairReason != nil { return "Needs a repair" }
        if wallet.openConflicts > 0 { return "Some records need a look" }
        guard let date = link.lastSyncedAt else { return "Connected" }
        return "Synced \(date.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Wallet")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                Text(status)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Choosing which Wallet accounts go to Sure, and where each one lands.
struct WalletSetupView: View {
    /// How far back to bring transactions in from.
    enum History: String, CaseIterable, Identifiable {
        case everything = "Everything Wallet has"
        case recent = "The last 90 days"
        case fromNow = "Only new activity"

        var id: String { rawValue }

        func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
            switch self {
            case .everything: nil
            case .recent: calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now))
            case .fromNow: now
            }
        }
    }

    let client: APIClient
    @Environment(WalletSync.self) private var wallet
    @Environment(\.dismiss) private var dismiss
    /// Nil until Wallet has answered.
    @State private var accounts: [WalletAccount]?
    @State private var hasAsked = false
    @State private var sureAccounts: [Account] = []
    @State private var selected: Set<String> = []
    /// The Sure account each Wallet account feeds. Missing means a new one.
    @State private var targets: [String: String] = [:]
    @State private var history = History.everything

    var body: some View {
        NavigationStack {
            Form {
                if let accounts, !accounts.isEmpty {
                    accountsSection(accounts)
                    Section {
                        Picker("Bring in", selection: $history) {
                            ForEach(History.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                    } footer: {
                        Text("Linking an account that already has these transactions in Sure? Choose only new activity, or they will show up twice.")
                    }
                    Section("By connecting, you agree that") {
                        agreement("The accounts you chose, with their balances and transactions, are sent to your Sure server\(client.baseURL.host().map { " at \($0)" } ?? "").")
                        agreement("Everyone in your Sure household can see them.")
                        agreement("Sure works on them on the server, not on this phone.")
                    }
                    Section {
                        if wallet.isWorking {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(wallet.activity ?? "Working")
                                    .foregroundStyle(Theme.muted)
                            }
                        } else {
                            Button("Agree and connect") {
                                Task { await connect(accounts) }
                            }
                            .font(Theme.bodyStrong)
                            .disabled(selected.isEmpty)
                        }
                    } footer: {
                        if let problem = wallet.problem, !wallet.isWorking {
                            Text(problem).foregroundStyle(Theme.negative)
                        }
                    }
                } else if hasAsked {
                    Section {
                        Text(accounts == nil
                            ? (wallet.problem ?? "Wallet could not be read.")
                            : "No Wallet accounts are shared with this app. Share them in the Settings app, then try again.")
                            .foregroundStyle(Theme.muted)
                        Button("Try again") {
                            Task { await ask() }
                        }
                        .disabled(wallet.isWorking)
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Asking Wallet")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .navigationTitle("Connect Apple Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(wallet.isWorking)
            .task { await ask() }
        }
    }

    private func accountsSection(_ accounts: [WalletAccount]) -> some View {
        Section {
            ForEach(accounts) { account in
                Toggle(isOn: isSelected(account.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                        Text(account.institutionName)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                    }
                }
                if selected.contains(account.id) {
                    Picker("Goes into", selection: target(account.id)) {
                        Text("A new \(WalletSetup.newAccountKind(for: account).label.lowercased()) account").tag("")
                        ForEach(sureAccounts.filter { WalletSetup.canLink(account, to: $0) }) { existing in
                            Text(existing.name).tag(existing.id)
                        }
                    }
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("A Wallet account can go into a Sure account of the same kind and currency, or a new one.")
        }
    }

    private func agreement(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark")
                .foregroundStyle(Theme.muted)
        }
    }

    private func isSelected(_ id: String) -> Binding<Bool> {
        Binding {
            selected.contains(id)
        } set: { isOn in
            if isOn { selected.insert(id) } else { selected.remove(id) }
        }
    }

    private func target(_ id: String) -> Binding<String> {
        Binding {
            targets[id] ?? ""
        } set: { value in
            targets[id] = value.isEmpty ? nil : value
        }
    }

    private func ask() async {
        async let existing = try? client.accounts()
        let shared = await wallet.walletAccounts()
        sureAccounts = await existing ?? []
        accounts = shared
        selected = Set(shared?.map(\.id) ?? [])
        hasAsked = true
    }

    private func connect(_ accounts: [WalletAccount]) async {
        let choices = accounts.filter { selected.contains($0.id) }.map { account in
            WalletSetupChoice(
                account: account,
                target: sureAccounts.first { $0.id == targets[account.id] }
            )
        }
        if await wallet.connect(choices, importSince: history.start()) {
            dismiss()
        }
    }
}

/// The records Sure held back, and what to do about each.
struct WalletReviewView: View {
    @Environment(WalletSync.self) private var wallet
    @State private var items: Loadable<[WalletReviewItem]> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Text("Sure will not overwrite a change made in Sure without asking. Keeping Sure's version is the safe choice. Taking Wallet's version needs a repair, which sends everything from Wallet again.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
                LoadableView(state: items, retry: load) { items in
                    if items.isEmpty {
                        Card { EmptyNote(text: "Nothing needs a look.") }
                    } else {
                        Button("Keep Sure's version for all \(items.count)") {
                            Task { await settle(items.map(\.conflict), keepingSure: true) }
                        }
                        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                        .disabled(wallet.isWorking)
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
                if let problem = wallet.problem, !wallet.isWorking {
                    Text(problem)
                        .font(Theme.small)
                        .foregroundStyle(Theme.negative)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Needs a look")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: WalletReviewItem) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                if let transaction = item.transaction {
                    Text(Self.title(of: transaction))
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.text)
                    Text("\(MoneyFormat.string(transaction.amount, currency: transaction.currency)) · \(transaction.transactedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Text(item.conflict.summary)
                    .font(Theme.body)
                    .foregroundStyle(item.transaction == nil ? Theme.text : Theme.muted)
            }
            HStack(spacing: 20) {
                Button("Keep Sure's") {
                    Task { await settle([item.conflict], keepingSure: true) }
                }
                Button("Take Wallet's") {
                    Task { await settle([item.conflict], keepingSure: false) }
                }
            }
            .font(Theme.smallStrong)
            .foregroundStyle(Theme.text)
            .disabled(wallet.isWorking)
        }
    }

    private static func title(of transaction: WalletTransaction) -> String {
        let merchant = transaction.merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !merchant.isEmpty { return merchant }
        return transaction.description.isEmpty ? "Wallet transaction" : transaction.description
    }

    private func load() async {
        items = await .fetching(keeping: items) {
            try await wallet.reviewItems()
        }
    }

    private func settle(_ conflicts: [WalletConflict], keepingSure: Bool) async {
        await wallet.resolve(conflicts, keepingSure: keepingSure)
        await load()
    }
}
