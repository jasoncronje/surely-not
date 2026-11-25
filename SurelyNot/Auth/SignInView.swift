import AuthenticationServices
import SwiftUI

/// Sign-in in two steps: first the server, then whichever way that server
/// lets people in. Asking the server first means the second step only shows
/// what will actually work there.
struct SignInView: View {
    /// A server that answered, and the sign-in services it offers.
    private struct Server: Equatable {
        let url: URL
        let providers: [SSOProvider]
    }

    private enum Method: Hashable {
        case singleSignOn, password, apiKey

        var switchLabel: String {
            switch self {
            case .singleSignOn: "Use single sign-on"
            case .password: "Use email and password"
            case .apiKey: "Use an API key"
            }
        }
    }

    private enum Input: Hashable {
        case server, email, password, code, apiKey
    }

    @Environment(Session.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @AppStorage("lastServerAddress") private var serverAddress = ""
    @State private var server: Server?
    @State private var method = Method.password
    @State private var email = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var needsTwoFactor = false
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Input?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let server {
                    signInStep(server)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                } else {
                    serverStep
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .screenColumn(margin: 24, maxWidth: Theme.formWidth)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Text("An unofficial app, not affiliated with the Sure project.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .screenBackground()
        .animation(.snappy(duration: 0.3), value: server)
        .animation(.snappy(duration: 0.3), value: method)
        .animation(.snappy(duration: 0.3), value: needsTwoFactor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProductMark(size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(server == nil ? "Connect to your Sure server" : "Sign in")
                    .font(Theme.title)
                    .foregroundStyle(Theme.text)
                    .contentTransition(.opacity)
                if server == nil {
                    Text("Surely Not shows your own Sure server's accounts, budgets and chat.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: - Step one: the server

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Field(label: "Server address", note: "The address you open Sure with in a browser.", isFocused: focus == .server) {
                TextField("sure.example.com", text: $serverAddress)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .submitLabel(.continue)
                    .onSubmit(connect)
                    .accessibilityIdentifier("serverAddress")
            }
            message
            WorkingButton(title: "Continue", workingTitle: "Checking the server", isWorking: isWorking, action: connect)
                .accessibilityIdentifier("continue")
        }
    }

    // MARK: - Step two: signing in

    private func signInStep(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.positive)
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Change", action: changeServer)
                    .font(Theme.smallStrong)
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 44)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minHeight: 56)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.controlRadius))

            if server.url.scheme?.lowercased() == "http" {
                Notice(
                    "This address is not encrypted. Your password and finances travel in plain text, so only use it on a network you trust.",
                    kind: .warning,
                    symbol: "lock.open.fill"
                )
            }

            switch method {
            case .singleSignOn:
                message
                ForEach(server.providers) { provider in
                    WorkingButton(
                        title: provider.label,
                        workingTitle: "Waiting for sign-in",
                        isWorking: isWorking
                    ) {
                        signIn(with: provider, on: server)
                    }
                }
            case .password:
                Field(label: "Email", isFocused: focus == .email) {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
                Field(label: "Password", isFocused: focus == .password) {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signInWithPassword(on: server) }
                }
                if needsTwoFactor {
                    Field(label: "Two-factor code", note: "From your authenticator app.", isFocused: focus == .code) {
                        TextField("123456", text: $otpCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focus, equals: .code)
                    }
                    .transition(.opacity)
                }
                message
                WorkingButton(title: "Sign in", workingTitle: "Signing in", isWorking: isWorking) {
                    signInWithPassword(on: server)
                }
                .accessibilityIdentifier("signIn")
            case .apiKey:
                Field(
                    label: "API key",
                    note: "Make one in Sure under Settings, API Key. A read-only key can show everything but change nothing.",
                    isFocused: focus == .apiKey
                ) {
                    HStack(spacing: 8) {
                        SecureField("Paste your key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .apiKey)
                            .submitLabel(.go)
                            .onSubmit { signInWithKey(on: server) }
                            .accessibilityIdentifier("apiKey")
                        Button("Paste") {
                            if let text = UIPasteboard.general.string {
                                apiKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .font(Theme.smallStrong)
                        .foregroundStyle(Theme.text)
                        .frame(minHeight: 44)
                    }
                }
                message
                WorkingButton(title: "Sign in", workingTitle: "Signing in", isWorking: isWorking) {
                    signInWithKey(on: server)
                }
                .accessibilityIdentifier("signIn")
            }

            otherMethods(for: server)
        }
    }

    /// The ways to sign in that are not on screen right now.
    private func otherMethods(for server: Server) -> some View {
        let all: [Method] = server.providers.isEmpty
            ? [.password, .apiKey]
            : [.singleSignOn, .password, .apiKey]
        return VStack(spacing: 4) {
            ForEach(all.filter { $0 != method }, id: \.self) { other in
                // With one service, name it: "Sign in with Pocket ID" says more.
                let label = other == .singleSignOn && server.providers.count == 1
                    ? server.providers[0].label
                    : other.switchLabel
                Button(label) {
                    errorMessage = nil
                    method = other
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("method-\(other)")
            }
        }
        .padding(.top, 4)
        .disabled(isWorking)
    }

    @ViewBuilder
    private var message: some View {
        if let text = errorMessage ?? session.notice {
            Notice(text)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func connect() {
        guard !isWorking else { return }
        guard let url = ServerAddress.normalise(serverAddress) else {
            errorMessage = serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Enter your server's address."
                : "That address does not look right. Try something like sure.example.com."
            focus = .server
            return
        }
        run {
            let probe = APIClient(baseURL: url, credential: nil, deviceID: Session.deviceID)
            var providers: [SSOProvider] = []
            do {
                providers = try await probe.ssoProviders()
            } catch let error as APIError where error.status == nil {
                // Nothing answered at that address, or it was not Sure.
                throw error
            } catch is APIError {
                // An older Sure server without single sign-on still signs in below.
            }
            focus = nil
            method = providers.isEmpty ? .password : .singleSignOn
            server = Server(url: url, providers: providers)
        }
    }

    private func changeServer() {
        errorMessage = nil
        needsTwoFactor = false
        otpCode = ""
        server = nil
    }

    private func signIn(with provider: SSOProvider, on server: Server) {
        guard let start = SingleSignOn.startURL(server: server.url, provider: provider.name, device: Session.deviceInfo) else {
            errorMessage = "Could not start sign-in with that server."
            return
        }
        run {
            let callback: URL
            do {
                callback = try await webAuthentication.authenticate(
                    using: start,
                    callback: .customScheme(SingleSignOn.callbackScheme),
                    // Shares Safari's sign-in, so someone already signed in to
                    // their provider there is not asked again, and passkeys
                    // behave as they do in Safari.
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return
            }
            switch SingleSignOn.outcome(from: callback) {
            case .code(let code):
                try await session.signIn(serverURL: server.url, ssoCode: code)
            case .twoFactorAccount:
                // Go straight to the form that will work, with the code field showing.
                method = .password
                needsTwoFactor = true
                errorMessage = "Sure does not allow \(provider.label.replacingOccurrences(of: "Sign in with ", with: "")) sign-in in apps for accounts with two-factor turned on. Use your email, password and code, or an API key."
            case .failed(let reason):
                errorMessage = reason
            }
        }
    }

    private func signInWithPassword(on server: Server) {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            errorMessage = "Enter your email."
            focus = .email
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Enter your password."
            focus = .password
            return
        }
        let code = otpCode.trimmingCharacters(in: .whitespaces)
        run {
            do {
                try await session.signIn(
                    serverURL: server.url,
                    email: address,
                    password: password,
                    otpCode: code.isEmpty ? nil : code
                )
            } catch let error as APIError where error.needsTwoFactor {
                let alreadyAsked = needsTwoFactor
                needsTwoFactor = true
                focus = .code
                if alreadyAsked {
                    throw APIError(status: error.status, message: "That code did not work. Try the newest one.")
                }
            }
        }
    }

    private func signInWithKey(on server: Server) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Paste your API key."
            focus = .apiKey
            return
        }
        run {
            try await session.signIn(serverURL: server.url, apiKey: key)
        }
    }

    /// Runs one sign-in step, showing progress and any error it ends with.
    private func run(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        errorMessage = nil
        session.notice = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A labelled input: the label above, the field in an outlined well, a note below.
private struct Field<Content: View>: View {
    let label: String
    var note: String?
    /// Whether the input inside has the keyboard. The screen tracks focus
    /// once, so the field is told rather than tracking it a second time.
    var isFocused = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
            content
                .font(Theme.body)
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(isFocused ? Theme.text : Theme.control, lineWidth: isFocused ? 1.5 : 1)
                }
                .animation(.snappy(duration: 0.15), value: isFocused)
            if let note {
                Text(note)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}
