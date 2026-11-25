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
                        disconnectCard
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
            .padding(.top, 8)
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
        .sheet(isPresented: $isConfirmingDisconnect) {
            WalletDisconnectSheet()
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
            VStack(alignment: .leading, spacing: 4) {
                Text(link.accounts.count == 1 ? "1 account connected" : "\(link.accounts.count) accounts connected")
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                if let host {
                    Text("Sending to \(host)")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            VStack(spacing: 14) {
                ForEach(link.accounts) { account in
                    HStack(spacing: 12) {
                        WalletAccountIcon(isLiability: account.isLiability)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(Theme.body)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(account.reportedUnavailable ? "No longer shared from Wallet"
                                : account.isLiability ? "Credit card" : "Cash")
                                .font(Theme.small)
                                .foregroundStyle(account.reportedUnavailable ? Theme.warning : Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 4) {
                FigureRow(label: "Last synced", value: lastSynced(link))
                if let outcome = syncOutcome {
                    Text(outcome)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            if !link.outbox.isEmpty {
                FigureRow(
                    label: "Waiting to upload",
                    value: "\(link.outbox.count) \(link.outbox.count == 1 ? "batch" : "batches")"
                )
            }
            if wallet.isWorking || wallet.repairNeeded == nil {
                WorkingButton(title: "Sync now", workingTitle: wallet.activity ?? "Working", isWorking: wallet.isWorking) {
                    Task { await wallet.sync() }
                }
            }
            Text("Wallet syncs when you open the app and when you tap Sync now, not while the app is closed.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
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
                    DisclosureChevron()
                }
                .cardSurface()
            }
            .buttonStyle(.plain)
        }

        disconnectCard
            .padding(.top, 16)
    }

    /// What the last sync did and what Wallet handed over, as one line.
    private var syncOutcome: String? {
        guard !wallet.isWorking, let outcome = wallet.lastOutcome else { return nil }
        guard let reading = wallet.lastReading else { return outcome }
        return "\(outcome) \(reading)"
    }

    private var disconnectCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Button("Disconnect Apple Wallet") {
                    isConfirmingDisconnect = true
                }
                .buttonStyle(TextButtonStyle(isDestructive: true))
                .disabled(wallet.isWorking)
                Text("Sure stops getting new activity. You choose whether to keep what it already has.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private var problemNote: some View {
        if let problem = wallet.problem, !wallet.isWorking {
            Notice(problem)
        }
    }

    private func lastSynced(_ link: WalletLink) -> String {
        guard let date = link.lastSyncedAt else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Asks how to disconnect: keep what Sure imported, or remove it too.
struct WalletDisconnectSheet: View {
    @Environment(WalletSync.self) private var wallet
    @State private var removing = false

    var body: some View {
        ConfirmSheet(
            title: "Disconnect Apple Wallet?",
            message: "Sure stops getting new activity from Wallet.",
            confirmTitle: removing ? "Disconnect and remove" : "Disconnect",
            isDestructive: removing
        ) {
            let remove = removing
            Task { await wallet.disconnect(removingImported: remove) }
        } options: {
            if wallet.serverCanDiscard {
                VStack(spacing: 0) {
                    ChoiceRow(
                        title: "Keep what was imported",
                        detail: "The accounts and transactions stay in Sure.",
                        isOn: !removing,
                        padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
                    ) { removing = false }
                    RowRule().padding(.horizontal, 16)
                    ChoiceRow(
                        title: "Remove what was imported",
                        detail: "Sure deletes the accounts and transactions Wallet sent. This cannot be undone.",
                        isOn: removing,
                        padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
                    ) { removing = true }
                }
                .rowGroup()
            }
        }
    }
}

/// A Wallet account's kind, as a quiet round icon: a card or cash.
struct WalletAccountIcon: View {
    let isLiability: Bool

    var body: some View {
        Image(systemName: isLiability ? "creditcard" : "banknote")
            .font(Theme.glyph)
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: 40)
            .background(Theme.raised, in: .circle)
            .accessibilityHidden(true)
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
                .font(Theme.glyph)
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
            DisclosureChevron()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .rowGroup()
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

        /// What the choice means, under its name.
        var detail: String {
            switch self {
            case .everything: "All the history Wallet holds."
            case .recent: "From three months ago onwards."
            case .fromNow: "Nothing before today. Pick this if Sure already has these transactions, or they will show up twice."
            }
        }

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

    private var host: String? { client.baseURL.host() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    if let accounts, !accounts.isEmpty {
                        accountsCard(accounts)
                        historyCard
                        agreementCard
                    } else if hasAsked {
                        Card {
                            Text(accounts == nil
                                ? (wallet.problem ?? "Wallet could not be read.")
                                : "No Wallet accounts are shared with this app. Share them in the Settings app, then try again.")
                                .font(Theme.body)
                                .foregroundStyle(Theme.muted)
                            Button("Try again") {
                                Task { await ask() }
                            }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                            .disabled(wallet.isWorking)
                        }
                    } else {
                        Card {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Asking Wallet")
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom) {
                if let accounts, !accounts.isEmpty {
                    connectBar(accounts)
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

    // MARK: - Accounts

    private func accountsCard(_ accounts: [WalletAccount]) -> some View {
        Card(title: "Accounts") {
            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        RowRule().padding(.vertical, 14)
                    }
                    accountRow(account)
                }
            }
            Text("An account can go into a Sure account of the same kind and currency, or a new one.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private func accountRow(_ account: WalletAccount) -> some View {
        let kind = WalletSetup.newAccountKind(for: account).label
        let isOn = selected.contains(account.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                WalletAccountIcon(isLiability: account.isLiability)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(kind) · \(account.institutionName)")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle(account.title, isOn: isSelected(account.id))
                    .labelsHidden()
                    .tint(Theme.positive)
            }
            if isOn {
                HStack(spacing: 8) {
                    Text("Goes into")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Goes into", selection: target(account.id)) {
                            Text("A new \(kind.lowercased()) account").tag("")
                            ForEach(sureAccounts.filter { WalletSetup.canLink(account, to: $0) }) { existing in
                                Text(existing.name).tag(existing.id)
                            }
                        }
                    } label: {
                        MenuChip(text: targetName(account, kind: kind), onCard: true)
                    }
                    .accessibilityLabel("Goes into \(targetName(account, kind: kind))")
                }
                // Lines up with the account's name, under its icon.
                .padding(.leading, 52)
            }
        }
        .animation(.snappy(duration: 0.2), value: isOn)
    }

    private func targetName(_ account: WalletAccount, kind: String) -> String {
        if let id = targets[account.id], let existing = sureAccounts.first(where: { $0.id == id }) {
            return existing.name
        }
        // The kind is already under the account's name.
        return "New account"
    }

    // MARK: - History

    private var historyCard: some View {
        Card(title: "Bring in") {
            VStack(spacing: 0) {
                ForEach(Array(History.allCases.enumerated()), id: \.element) { index, choice in
                    if index > 0 {
                        RowRule()
                    }
                    ChoiceRow(title: choice.rawValue, detail: choice.detail, isOn: history == choice) {
                        history = choice
                    }
                }
            }
            .padding(.vertical, -12)
        }
    }

    // MARK: - Agreement and connect

    private var agreementCard: some View {
        Card(title: "By connecting, you agree that") {
            VStack(alignment: .leading, spacing: 12) {
                agreement("The accounts you chose, with their balances and transactions, are sent to your Sure server\(host.map { " at \($0)" } ?? "").")
                agreement("Everyone in your Sure household can see them.")
                agreement("Sure works on them on the server, not on this phone.")
            }
        }
    }

    private func agreement(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Theme.muted)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectBar(_ accounts: [WalletAccount]) -> some View {
        VStack(spacing: 10) {
            if let problem = wallet.problem, !wallet.isWorking {
                Notice(problem)
            }
            WorkingButton(
                title: selected.isEmpty ? "Choose an account" : "Agree and connect",
                workingTitle: wallet.activity ?? "Working",
                isWorking: wallet.isWorking
            ) {
                Task { await connect(accounts) }
            }
            .disabled(selected.isEmpty && !wallet.isWorking)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.ground)
    }

    // MARK: - State

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
                    Notice(problem)
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
