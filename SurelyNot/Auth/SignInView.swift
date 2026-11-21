import SwiftUI

struct SignInView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case password = "Email"
        case apiKey = "API key"
        var id: Self { self }
    }

    @Environment(Session.self) private var session
    @AppStorage("lastServerAddress") private var serverAddress = ""
    @State private var method = Method.password
    @State private var email = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("sure.example.com", text: $serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("serverAddress")
                } header: {
                    Text("Your Sure server")
                } footer: {
                    Text("The address you use to open Sure in a browser.")
                }

                Section {
                    Picker("Sign in with", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch method {
                    case .password:
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        TextField("Two-factor code (if you use one)", text: $otpCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    case .apiKey:
                        SecureField("API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("apiKey")
                    }
                } footer: {
                    if method == .apiKey {
                        Text("Create a key in Sure under Settings, API Key. A read-only key lets you view everything but not add or change anything.")
                    }
                }

                if let message = errorMessage ?? session.notice {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign in")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(!canSubmit || isWorking)
                    .accessibilityIdentifier("signIn")
                } footer: {
                    Text("Surely Not is an unofficial app. It is not affiliated with the Sure project.")
                }
            }
            .navigationTitle("Surely Not")
        }
    }

    private var canSubmit: Bool {
        guard !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch method {
        case .password: return !email.isEmpty && !password.isEmpty
        case .apiKey: return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func signIn() {
        guard let url = ServerAddress.normalise(serverAddress) else {
            errorMessage = "That server address does not look right. Try something like sure.example.com."
            return
        }
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch method {
                case .password:
                    let code = otpCode.trimmingCharacters(in: .whitespaces)
                    try await session.signIn(
                        serverURL: url,
                        email: email.trimmingCharacters(in: .whitespaces),
                        password: password,
                        otpCode: code.isEmpty ? nil : code
                    )
                case .apiKey:
                    try await session.signIn(
                        serverURL: url,
                        apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
