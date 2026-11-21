import SwiftUI

struct SignInView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case password = "Email and password"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    ProductMark(size: 44)
                    Text("Surely Not")
                        .font(Theme.title)
                        .foregroundStyle(Theme.text)
                    Text("Your own Sure server, in a native iPhone app.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 16) {
                    Field(label: "Server address", note: "The address you use to open Sure in a browser.") {
                        TextField("sure.example.com", text: $serverAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("serverAddress")
                    }

                    Picker("Sign in with", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch method {
                    case .password:
                        Field(label: "Email") {
                            TextField("you@example.com", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Field(label: "Password") {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                        Field(label: "Two-factor code", note: "Only if you have turned on two-factor sign-in.") {
                            TextField("123456", text: $otpCode)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                        }
                    case .apiKey:
                        Field(
                            label: "API key",
                            note: "Create one in Sure under Settings, API Key. A read-only key lets you see everything but change nothing."
                        ) {
                            SecureField("Paste your key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("apiKey")
                        }
                    }
                }
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                // The keyboard covers the button below, so its return key signs in too.
                .submitLabel(.go)
                .onSubmit {
                    if canSubmit, !isWorking { signIn() }
                }

                if let message = errorMessage ?? session.notice {
                    Text(message)
                        .font(Theme.small)
                        .foregroundStyle(Theme.negative)
                        .padding(.horizontal, 4)
                }

                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView().tint(Theme.onPrimary)
                        }
                        Text(isWorking ? "Signing in" : "Sign in")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(!canSubmit || isWorking)
                .accessibilityIdentifier("signIn")

                Text("Surely Not is an unofficial app. It is not affiliated with the Sure project.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
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

/// A labelled input: the label above, the field in a grey well, a note below.
private struct Field<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
            content
                .font(Theme.body)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Theme.ground, in: .rect(cornerRadius: Theme.controlRadius))
            if let note {
                Text(note)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}
