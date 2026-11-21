import SwiftUI

@main
struct SurelyNotApp: App {
    @State private var session = Session()

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
            .environment(session)
            .font(Theme.body)
            // Controls stay neutral. Colour is kept for the data.
            .tint(Theme.text)
        }
    }
}

struct MainTabView: View {
    let client: APIClient

    var body: some View {
        TabView {
            Tab("Overview", systemImage: "chart.pie") {
                OverviewView(client: client)
            }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                ChatListView(client: client)
            }
            Tab("Budgets", systemImage: "target") {
                BudgetsView(client: client)
            }
            Tab("Accounts", systemImage: "building.columns") {
                AccountsView(client: client)
            }
        }
        // The tab bar shrinks out of the way while reading down a screen and
        // comes back on scrolling up.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

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
