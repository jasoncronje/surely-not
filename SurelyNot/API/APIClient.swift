import Foundation

/// How the app proves who it is to a Sure server.
nonisolated enum Credential: Codable, Sendable, Equatable {
    /// A personal API key, sent as `X-Api-Key`.
    case apiKey(String)
    /// Tokens from email and password sign-in, sent as a bearer token.
    case token(access: String, refresh: String)
}

nonisolated struct APIError: LocalizedError, Sendable {
    /// HTTP status, or nil when the request never reached the server.
    let status: Int?
    let message: String
    /// The server wants a two-factor code before it will sign this person in.
    var needsTwoFactor = false

    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}

/// Talks to one Sure server's REST API.
final class APIClient {
    let baseURL: URL
    private(set) var credential: Credential?
    private let deviceID: String
    private let session: URLSession
    private var refreshTask: Task<Credential, Error>?

    /// Called when a token refresh replaces the credential, so it can be saved.
    var onCredentialChange: ((Credential) -> Void)?
    /// Called when the server rejects the credential and it cannot be refreshed.
    var onSessionExpired: (() -> Void)?

    init(baseURL: URL, credential: Credential?, deviceID: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credential = credential
        self.deviceID = deviceID
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    // MARK: - Requests

    func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [String: String?] = [:]
    ) async throws -> Response {
        let data = try await perform(method: "GET", path: path, query: query, body: nil)
        return try decode(data)
    }

    func send<Response: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        body: (any Encodable & Sendable)? = nil
    ) async throws -> Response {
        let data = try await perform(method: method, path: path, query: [:], body: try encode(body))
        return try decode(data)
    }

    /// For endpoints whose response body the app does not need.
    func sendDiscardingResponse(
        _ method: String,
        _ path: String,
        body: (any Encodable & Sendable)? = nil
    ) async throws {
        _ = try await perform(method: method, path: path, query: [:], body: try encode(body))
    }

    private func encode(_ body: (any Encodable & Sendable)?) throws -> Data? {
        guard let body else { return nil }
        return try Self.encoder.encode(body)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError(status: nil, message: "The server sent a reply this app could not read.")
        }
    }

    private func perform(
        method: String,
        path: String,
        query: [String: String?],
        body: Data?,
        allowRefresh: Bool = true
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: "api/v1/\(path)"),
            resolvingAgainstBaseURL: false
        )
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components?.queryItems = items.sorted { $0.name < $1.name }
        }
        guard let url = components?.url else {
            throw APIError(status: nil, message: "The server address is not valid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        switch credential {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        case .token(let access, _):
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        case nil:
            break
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError(status: nil, message: "Could not reach the server. \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: nil, message: "The server sent an unexpected reply.")
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }

        if http.statusCode == 401, allowRefresh, case .token(_, let refresh) = credential {
            do {
                credential = try await refreshed(using: refresh)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onSessionExpired?()
                throw APIError(status: 401, message: "Your session has expired. Please sign in again.")
            }
            return try await perform(method: method, path: path, query: query, body: body, allowRefresh: false)
        }

        if http.statusCode == 401, credential != nil {
            onSessionExpired?()
        }
        let needsTwoFactor = (try? Self.decoder.decode(ErrorResponse.self, from: data))?.mfaRequired ?? false
        throw APIError(
            status: http.statusCode,
            message: Self.message(for: http.statusCode, data: data),
            needsTwoFactor: needsTwoFactor
        )
    }

    /// Exchanges the refresh token for new tokens. Requests that fail at the
    /// same moment share one refresh, because a refresh token works only once.
    private func refreshed(using refreshToken: String) async throws -> Credential {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { () throws -> Credential in
            let input = RefreshInput(refreshToken: refreshToken, device: DeviceInfo(deviceId: deviceID))
            let data = try await perform(
                method: "POST",
                path: "auth/refresh",
                query: [:],
                body: try Self.encoder.encode(input),
                allowRefresh: false
            )
            let tokens = try Self.decoder.decode(TokenResponse.self, from: data)
            return .token(access: tokens.accessToken, refresh: tokens.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let credential = try await task.value
        onCredentialChange?(credential)
        return credential
    }

    private static func message(for status: Int, data: Data) -> String {
        if let body = try? decoder.decode(ErrorResponse.self, from: data) {
            if let errors = body.errors, !errors.isEmpty {
                return errors.joined(separator: " ")
            }
            if let message = body.message, !message.isEmpty {
                return message
            }
            if let error = body.error, !error.isEmpty {
                return humanised(error)
            }
        }
        switch status {
        case 401: return "The server did not accept your sign-in details."
        case 403: return "You are not allowed to do that. An API key may be read-only."
        case 404: return "The server does not have that. It may be running an older version of Sure."
        case 500...: return "The server had a problem (error \(status))."
        default: return "The request failed (error \(status))."
        }
    }

    /// Turns a code such as `invalid_credentials` into a readable sentence.
    private static func humanised(_ error: String) -> String {
        guard !error.contains(" ") else { return error }
        let words = error.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst() + "."
    }
}

// MARK: - Endpoints

extension APIClient {
    func login(email: String, password: String, otpCode: String?, device: DeviceInfo) async throws -> Credential {
        let input = LoginInput(email: email, password: password, otpCode: otpCode, device: device)
        let tokens: TokenResponse = try await send("POST", "auth/login", body: input)
        return .token(access: tokens.accessToken, refresh: tokens.refreshToken)
    }

    /// The other services this server lets people sign in with. Needs no sign-in.
    func ssoProviders() async throws -> [SSOProvider] {
        let list: SSOProviderList = try await get("auth/sso_providers")
        return list.providers
    }

    /// Trades the one-time code from a finished single sign-on for tokens.
    func exchangeSSO(code: String) async throws -> Credential {
        let tokens: TokenResponse = try await send("POST", "auth/sso_exchange", body: SSOExchangeInput(code: code))
        return .token(access: tokens.accessToken, refresh: tokens.refreshToken)
    }

    func accounts() async throws -> [Account] {
        let page: Page<Account> = try await get("accounts", query: ["per_page": "100"])
        return page.items
    }

    func balanceSheet() async throws -> BalanceSheet {
        try await get("balance_sheet")
    }

    func cashFlow() async throws -> CashFlow {
        try await get("cash_flow")
    }

    func spendingVsNormal(startDate: String? = nil, endDate: String? = nil) async throws -> SpendingVsNormal {
        try await get("spending_vs_normal", query: ["start_date": startDate, "end_date": endDate])
    }

    func insights() async throws -> [Insight] {
        let list: InsightList = try await get("insights")
        return list.insights
    }

    func acknowledgeInsight(id: String) async throws {
        try await sendDiscardingResponse("PATCH", "insights/\(id)/acknowledge")
    }

    func budgets() async throws -> [Budget] {
        let page: Page<Budget> = try await get("budgets", query: ["per_page": "36"])
        return page.items
    }

    func budgetCategories(budgetID: String) async throws -> [BudgetCategory] {
        let page: Page<BudgetCategory> = try await get(
            "budget_categories",
            query: ["budget_id": budgetID, "per_page": "100"]
        )
        return page.items
    }

    func categories() async throws -> [CategoryRef] {
        let page: Page<CategoryRef> = try await get("categories", query: ["per_page": "100"])
        return page.items
    }

    func transactions(matching filter: TransactionFilter, page: Int, perPage: Int = 30) async throws -> Page<Transaction> {
        var query = filter.query()
        query["page"] = String(page)
        query["per_page"] = String(perPage)
        return try await get("transactions", query: query)
    }

    /// Every repeating payment Sure knows of, confirmed or only suggested.
    func bills() async throws -> [Bill] {
        let page: Page<Bill> = try await get("recurring_transactions", query: ["per_page": "100"])
        return page.items
    }

    /// Starts or stops tracking a repeating payment as a bill.
    func setBill(id: String, tracked: Bool) async throws {
        let body = BillUpdate(recurringTransaction: .init(status: tracked ? "active" : "inactive"))
        try await sendDiscardingResponse("PATCH", "recurring_transactions/\(id)", body: body)
    }

    func createTransaction(_ input: TransactionInput) async throws -> Transaction {
        try await send("POST", "transactions", body: TransactionEnvelope(transaction: input))
    }

    func updateTransaction(id: String, _ input: TransactionInput) async throws -> Transaction {
        try await send("PATCH", "transactions/\(id)", body: TransactionEnvelope(transaction: input))
    }

    func deleteTransaction(id: String) async throws {
        try await sendDiscardingResponse("DELETE", "transactions/\(id)")
    }

    func balances(accountID: String, since startDate: String) async throws -> [BalancePoint] {
        let page: Page<BalancePoint> = try await get(
            "balances",
            query: ["account_id": accountID, "start_date": startDate, "per_page": "100"]
        )
        return page.items
    }

    func holdings(accountID: String) async throws -> [Holding] {
        let page: Page<Holding> = try await get("holdings", query: ["account_id": accountID, "per_page": "100"])
        return page.items
    }

    func chats() async throws -> [Chat] {
        let page: Page<Chat> = try await get("chats")
        return page.items
    }

    func chat(id: String) async throws -> Chat {
        try await get("chats/\(id)")
    }

    func createChat(firstMessage: String) async throws -> Chat {
        let title = String(firstMessage.prefix(60))
        return try await send("POST", "chats", body: NewChatInput(title: title, message: firstMessage))
    }

    func renameChat(id: String, title: String) async throws {
        try await sendDiscardingResponse("PATCH", "chats/\(id)", body: ChatTitleInput(title: title))
    }

    func deleteChat(id: String) async throws {
        try await sendDiscardingResponse("DELETE", "chats/\(id)")
    }

    func sendMessage(chatID: String, content: String) async throws {
        try await sendDiscardingResponse("POST", "chats/\(chatID)/messages", body: NewMessageInput(content: content))
    }

    func retryLastMessage(chatID: String) async throws {
        try await sendDiscardingResponse("POST", "chats/\(chatID)/messages/retry")
    }
}
