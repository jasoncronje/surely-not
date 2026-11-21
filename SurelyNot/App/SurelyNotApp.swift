import SwiftUI

@main
struct SurelyNotApp: App {
    @State private var session = Session()

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
    }
}

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Text(session.serverURL?.absoluteString ?? "Not signed in")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        session.signOut()
                    }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("Surely Not is an unofficial, open source app. It is not affiliated with the Sure project.")
                }
            }
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
