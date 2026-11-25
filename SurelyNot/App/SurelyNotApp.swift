import SwiftUI

@main
struct SurelyNotApp: App {
    @State private var session = Session()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.applyBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let client = session.client {
                    MainTabView(client: client)
                        // A new sign-in gets fresh screens with no data from the last one.
                        .id(ObjectIdentifier(client))
                } else {
                    SignInView()
                }
            }
            // Nothing shows under the cover, even for the first frame of a cold start.
            .opacity(lock.cover == .none ? 1 : 0)
            .environment(session)
            .environment(lock)
            .task { lock.start() }
            .font(Theme.body)
            // Controls stay neutral. Colour is kept for the data.
            .tint(Theme.text)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background, session.isSignedIn {
                WidgetFeed.scheduleRefresh()
            }
        }
        // iOS wakes the app now and then to keep the widget's bills current.
        .backgroundTask(.appRefresh(WidgetFeed.refreshTask)) {
            if let client = await session.client {
                await WidgetFeed.refresh(client: client)
            }
        }
    }
}

struct MainTabView: View {
    let client: APIClient
    @State private var changes: LedgerChanges
    @State private var categoryChanger: CategoryChanger
    @State private var wallet: WalletSync
    @Environment(\.scenePhase) private var scenePhase

    init(client: APIClient) {
        self.client = client
        let changes = LedgerChanges()
        _changes = State(initialValue: changes)
        _categoryChanger = State(initialValue: CategoryChanger(client: client, changes: changes))
        let wallet = WalletSync(client: client)
        // New Wallet data changes balances and lists across the app.
        wallet.onImported = { changes.noteChange() }
        _wallet = State(initialValue: wallet)
    }

    var body: some View {
        TabView {
            Tab("Overview", systemImage: "chart.pie") {
                OverviewView(client: client)
            }
            Tab("Transactions", systemImage: "list.bullet") {
                NavigationStack {
                    TransactionsView(client: client, isRoot: true)
                }
            }
            Tab("Budgets", systemImage: "target") {
                BudgetsView(client: client)
            }
            Tab("Accounts", systemImage: "building.columns") {
                AccountsView(client: client)
            }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                ChatListView(client: client)
            }
        }
        // The tab bar shrinks out of the way while reading down a screen and
        // comes back on scrolling up.
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(changes)
        .environment(categoryChanger)
        .environment(wallet)
        .task { await categoryChanger.loadIfNeeded() }
        // Wallet can only be read while the app is open, so each time the
        // app comes to the front it sends what is new.
        .task { await wallet.syncIfDue() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await wallet.syncIfDue() }
            }
        }
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { categoryChanger.error != nil },
                set: { if !$0 { categoryChanger.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(categoryChanger.error ?? "")
        }
    }
}

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    /// The switch follows the lock; flipping it asks before anything changes.
    private var lockIsOn: Binding<Bool> {
        Binding(get: { lock.isEnabled }, set: { wanted in
            Task { await lock.setEnabled(wanted) }
        })
    }

    @State private var remindersOn = BillReminders.isEnabled
    @State private var remindersWaiting = 0
    @State private var remindersRefused = false

    /// Flipping the switch asks iOS for permission before it stays on.
    private var remindersBinding: Binding<Bool> {
        Binding(get: { remindersOn }, set: { wanted in
            remindersOn = wanted
            Task {
                if wanted {
                    if await BillReminders.enable() {
                        // Loading the bills is what puts the reminders in place.
                        if let client = session.client {
                            await BillsModel(client: client).load()
                        }
                    } else {
                        remindersOn = false
                        remindersRefused = true
                    }
                } else {
                    await BillReminders.disable()
                }
                remindersWaiting = await BillReminders.waitingCount()
            }
        })
    }

    private var remindersNote: String {
        guard remindersOn else { return "A notification at 9 in the morning, the day before each bill." }
        switch remindersWaiting {
        case 0: return "On. Nothing is due soon."
        case 1: return "On. 1 reminder is waiting."
        default: return "On. \(remindersWaiting) reminders are waiting."
        }
    }

    private var lockErrorShown: Binding<Bool> {
        Binding(
            get: { !(lock.error ?? "").isEmpty },
            set: { if !$0 { lock.error = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    Card {
                        HStack(spacing: 12) {
                            ProductMark(size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Surely Not")
                                    .font(Theme.bodyStrong)
                                    .foregroundStyle(Theme.text)
                                Text("Version \(appVersion)")
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        RowRule()
                        FigureRow(label: "Server", value: session.serverURL?.host() ?? "Not signed in")
                    }
                    Card {
                        Toggle(isOn: lockIsOn) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lock with \(lock.methodName)")
                                    .font(Theme.bodyStrong)
                                    .foregroundStyle(Theme.text)
                                Text("Asks when you open the app, and after a minute away.")
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .tint(Theme.accent)
                    }
                    Card {
                        Toggle(isOn: remindersBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bill reminders")
                                    .font(Theme.bodyStrong)
                                    .foregroundStyle(Theme.text)
                                Text(remindersNote)
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .tint(Theme.accent)
                    }
                    Button("Sign out") {
                        session.signOut()
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    Text("Surely Not is an unofficial, open source app. It is not affiliated with the Sure project.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4)
                }
                .padding(Theme.margin)
            }
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { remindersWaiting = await BillReminders.waitingCount() }
            .alert("Notifications are off", isPresented: $remindersRefused) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow notifications for Surely Not in the Settings app, then turn reminders on again.")
            }
            .alert("The lock was not changed", isPresented: lockErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lock.error ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}
