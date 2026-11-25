import Foundation

/// The parts of Sure's API that set up and look after a Wallet connection.
/// These use the person's normal sign-in.
protocol WalletServer: AnyObject {
    func walletCapabilities() async throws -> WalletCapabilities
    func walletEnroll(_ enrollment: WalletEnrollment) async throws -> WalletConnection
    func walletMap(connectionID: String, sourceID: String, _ request: WalletMappingRequest) async throws
    /// Makes the connection live and hands over the upload key.
    func walletActivate(connectionID: String) async throws -> WalletPublisherConfiguration
    /// Swaps the upload key for a new one. The stream carries on.
    func walletRenewCredential(connectionID: String) async throws -> WalletPublisherConfiguration
    /// Starts a fresh stream after the old one has broken.
    func walletRepair(connectionID: String) async throws -> WalletPublisherConfiguration
    func walletConnection(id: String) async throws -> WalletConnection
    func walletMappings(connectionID: String) async throws -> [WalletMapping]
    /// `discard` also removes what the connection imported.
    func walletDisconnect(connectionID: String, discard: Bool) async throws
    func walletConflicts(connectionID: String) async throws -> [WalletConflict]
    func walletResolve(connectionID: String, conflictID: String, keepSure: Bool) async throws
}

extension APIClient: WalletServer {
    func walletCapabilities() async throws -> WalletCapabilities {
        try await get("financekit/capabilities")
    }

    func walletEnroll(_ enrollment: WalletEnrollment) async throws -> WalletConnection {
        try await send("POST", "financekit/connections", body: enrollment)
    }

    func walletMap(connectionID: String, sourceID: String, _ request: WalletMappingRequest) async throws {
        try await sendDiscardingResponse(
            "PUT",
            "financekit/connections/\(connectionID)/account_mappings/\(sourceID)",
            body: request
        )
    }

    func walletActivate(connectionID: String) async throws -> WalletPublisherConfiguration {
        try await send("POST", "financekit/connections/\(connectionID)/activate")
    }

    func walletRenewCredential(connectionID: String) async throws -> WalletPublisherConfiguration {
        try await send("POST", "financekit/connections/\(connectionID)/credential")
    }

    func walletRepair(connectionID: String) async throws -> WalletPublisherConfiguration {
        try await send("POST", "financekit/connections/\(connectionID)/repair")
    }

    func walletConnection(id: String) async throws -> WalletConnection {
        try await get("financekit/connections/\(id)")
    }

    func walletMappings(connectionID: String) async throws -> [WalletMapping] {
        let detail: WalletConnectionDetail = try await get(
            "financekit/connections/\(connectionID)",
            query: ["per_page": "100"]
        )
        return detail.accounts ?? []
    }

    func walletDisconnect(connectionID: String, discard: Bool) async throws {
        try await sendDiscardingResponse(
            "DELETE",
            "financekit/connections/\(connectionID)",
            query: ["disposition": discard ? "discard" : nil]
        )
    }

    func walletConflicts(connectionID: String) async throws -> [WalletConflict] {
        let list: WalletConflictList = try await get(
            "financekit/connections/\(connectionID)/conflicts",
            query: ["per_page": "100"]
        )
        return list.conflicts
    }

    func walletResolve(connectionID: String, conflictID: String, keepSure: Bool) async throws {
        try await sendDiscardingResponse(
            "PATCH",
            "financekit/connections/\(connectionID)/conflicts/\(conflictID)",
            body: WalletConflictResolution(resolution: keepSure ? "keep_sure" : "retry_after_repair")
        )
    }
}

/// A connection together with the accounts it feeds.
nonisolated struct WalletConnectionDetail: Decodable, Sendable {
    let accounts: [WalletMapping]?
}

/// What came of sending one batch.
nonisolated enum WalletUploadResult: Sendable, Equatable {
    case accepted(WalletReceipt)
    /// Sure answered and said no. `code` is its reason, such as `repair_required`.
    case refused(status: Int, code: String?)
    /// The batch never reached Sure.
    case unreachable(String)
}

nonisolated protocol WalletUploading: Sendable {
    func upload(
        _ payload: Data,
        batch: WalletQueuedBatch,
        publisherId: String,
        credential: String
    ) async -> WalletUploadResult
}

/// Sends batches to Sure with the connection's upload key. That key can
/// add Wallet data to one connection and do nothing else: it cannot read
/// anything from Sure.
nonisolated struct WalletUploader: WalletUploading {
    let baseURL: URL
    var session: URLSession = .shared

    func upload(
        _ payload: Data,
        batch: WalletQueuedBatch,
        publisherId: String,
        credential: String
    ) async -> WalletUploadResult {
        // Wallet data never leaves the phone unencrypted, whatever let it get this far.
        guard baseURL.scheme?.lowercased() == "https" else {
            return .unreachable("Wallet data is only sent over https://.")
        }
        let url = baseURL.appending(path: "api/v1/financekit/publishers/\(publisherId)/batches")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        // Sure checks the bytes against this, and treats a repeat of the same
        // batch as the same batch, so a retry after a lost reply is harmless.
        request.setValue(batch.digest, forHTTPHeaderField: "X-Sure-Payload-SHA256")
        request.setValue(batch.batchId, forHTTPHeaderField: "Idempotency-Key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .unreachable("The server sent an unexpected reply.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(http.statusCode) else {
            let reply = try? decoder.decode(ErrorResponse.self, from: data)
            return .refused(status: http.statusCode, code: reply?.error)
        }
        let receipt = (try? decoder.decode(WalletReceipt.self, from: data))
            ?? WalletReceipt(batchId: batch.batchId, sequence: batch.sequence, status: "accepted", errorCode: nil)
        return .accepted(receipt)
    }
}
