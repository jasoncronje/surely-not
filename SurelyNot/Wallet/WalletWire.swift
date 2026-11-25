import CryptoKit
import Foundation

// What the app sends to Sure's Apple Wallet API (/api/v1/financekit), and
// what Sure sends back. Sure rejects a record with a missing key, an unknown
// key or a null, so every type here encodes exactly the keys Sure lists.

nonisolated enum WalletWire {
    /// The version of Sure's Wallet upload protocol this app speaks.
    static let protocolVersion = 2
    /// Sure's limits, used until the server states its own.
    static let maxRecordsPerBatch = 500
    static let maxBytesPerBatch = 1_048_576
    /// The most parts one capture may be split into.
    static let maxChunksPerCapture = 100

    /// Encodes with snake_case keys, in a fixed key order so that the same
    /// records always give the same bytes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Sure matches some IDs exactly as text, so every ID is sent in lowercase.
    static func id(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    static func newID() -> String {
        id(UUID())
    }

    /// A moment as Sure reads it: UTC, to the millisecond, ending in "Z".
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Reads a moment Sure sent, with or without fractions of a second.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// Drops anything finer than a millisecond, so a moment survives being
    /// written as text and read back.
    static func wholeMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    /// A number written out in full, such as "1250.5", with at most `scale`
    /// decimals and no sign. Nil for a value that is not a number.
    static func plain(_ value: Decimal, scale: Int) -> String? {
        guard !value.isNaN else { return nil }
        var input = value.magnitude
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, scale, .plain)
        return NSDecimalString(&rounded, Locale(identifier: "en_US_POSIX"))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Cuts text down to the length Sure accepts. Sure counts Unicode
    /// scalars, so an emoji can count as several.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }
}

/// An amount, its currency, and whether it is money in (`credit`) or out (`debit`).
nonisolated struct WalletMoney: Codable, Sendable, Equatable {
    let amount: String
    let currency: String
    let direction: String

    /// Nil when Sure would refuse the amount or the currency. Sure takes up
    /// to 15 digits before the point and 4 after.
    init?(amount: Decimal, currency: String, isCredit: Bool) {
        guard let text = WalletWire.plain(amount, scale: 4),
              text.wholeMatch(of: /(0|[1-9][0-9]{0,14})(\.[0-9]{1,4})?/) != nil,
              currency.count == 3, currency == currency.uppercased() else { return nil }
        self.amount = text
        self.currency = currency
        // Sure wants the size and the direction apart. A negative amount is
        // the same size the other way.
        let credit = amount < 0 ? !isCredit : isCredit
        direction = credit ? "credit" : "debit"
    }

    static func zero(currency: String) -> WalletMoney? {
        WalletMoney(amount: 0, currency: currency, isCredit: false)
    }
}

// MARK: - Setting up

/// What the person agreed to when they connected Wallet. Sure refuses a
/// connection unless all three statements are true.
nonisolated struct WalletConsent: Codable, Sendable, Equatable {
    var version = 1
    let grantedAt: String
    let selectedSourceAccountIds: [String]
    var uploadAuthorized = true
    var familyVisibilityAcknowledged = true
    var remoteProcessingAcknowledged = true
}

/// Asks Sure to start a Wallet connection for this phone.
nonisolated struct WalletEnrollment: Codable, Sendable, Equatable {
    let enrollmentId: String
    var protocolVersion = WalletWire.protocolVersion
    let consent: WalletConsent
}

/// Says which Sure account one Wallet account feeds: a new one, or one that
/// already exists.
nonisolated struct WalletMappingRequest: Codable, Sendable, Equatable {
    var expectedVersion = 0
    /// `create` or `link`.
    let action: String
    let name: String
    let institutionName: String
    let currency: String
    /// `CreditCard` or `Depository`.
    let accountableType: String
    let subtype: String
    let ledgerTimezone: String
    /// Only when linking.
    var accountId: String?
    /// Only when creating.
    var bookedBalance: WalletMoney?
    var observedAt: String?
}

nonisolated struct WalletCapabilities: Decodable, Sendable {
    let protocolVersions: [Int]?
    let maxRecords: Int?
    let maxPayloadBytes: Int?
    let maxAccounts: Int?
    let connectionDispositions: [String]?

    var speaksThisProtocol: Bool {
        protocolVersions?.contains(WalletWire.protocolVersion) ?? false
    }

    /// Whether Sure can also remove what a connection imported.
    var canDiscard: Bool {
        connectionDispositions?.contains("discard") ?? false
    }
}

/// A Wallet connection as Sure sees it.
nonisolated struct WalletConnection: Decodable, Sendable, Equatable {
    let id: String
    let publisherId: String
    /// `pending_mapping`, `active`, `repair_required` or `revoked`.
    let status: String
    let generation: Int
    let streamId: String?
    /// The number of the next batch Sure will import.
    let nextSequence: Int?
    let repairReason: String?
    let lastAcceptedAt: String?
    let lastImportedAt: String?
    let openConflicts: Int?
    let purgeRequestedAt: String?
    let purgeCompletedAt: String?

    var isActive: Bool { status == "active" }
    var needsRepair: Bool { status == "repair_required" }
    var isRevoked: Bool { status == "revoked" }
}

nonisolated struct WalletMapping: Decodable, Sendable, Equatable {
    let sourceId: String
    let mappingVersion: Int
    let lineageId: String
    /// The Sure account this Wallet account feeds.
    let accountId: String?
}

/// What Sure hands over when a connection goes live: where the stream
/// stands, and the one-purpose key that lets this phone upload to it.
nonisolated struct WalletPublisherConfiguration: Decodable, Sendable {
    nonisolated struct Binding: Decodable, Sendable, Equatable {
        let sourceAccountId: String
        let lineageId: String
        let mappingVersion: Int
    }

    let id: String
    let publisherId: String
    let status: String
    let generation: Int
    let streamId: String
    let nextSequence: Int
    let accountBindings: [Binding]
    let maxRecordsPerBatch: Int?
    let maxBytesPerBatch: Int?
    let publisherCredential: String
}

/// Sure's acknowledgement of one uploaded batch.
nonisolated struct WalletReceipt: Decodable, Sendable, Equatable {
    let batchId: String?
    let sequence: Int?
    /// `accepted`, `processing`, `applied`, `failed` or `revoked`.
    let status: String
    let errorCode: String?

    /// Sure took the batch and then gave up on it or cancelled it.
    var wasDropped: Bool { status == "failed" || status == "revoked" }
}

/// Something Sure would not import without asking, because it would undo a
/// change made in Sure.
nonisolated struct WalletConflict: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let kind: String
    let status: String?
    let details: [String: String]?

    /// The Wallet transaction it is about, if it is about one.
    var sourceID: String? {
        guard kind != "balance_observation_conflict" else { return nil }
        return (details?["sourceId"] ?? details?["source_id"])?.lowercased()
    }

    var summary: String {
        switch kind {
        case "protected_entry", "protected_source_update":
            "Wallet changed a transaction that was edited in Sure."
        case "protected_tombstone":
            "Wallet removed a transaction that was edited in Sure."
        case "source_reappeared":
            "Wallet brought back a transaction that was removed."
        case "replacement_identity":
            "A transaction arrived after this phone took over from another."
        case "balance_observation_conflict":
            "Wallet reported two different balances for the same moment."
        default:
            "Wallet and Sure disagree about a record."
        }
    }
}

nonisolated struct WalletConflictList: Decodable, Sendable {
    let conflicts: [WalletConflict]
}

nonisolated struct WalletConflictResolution: Encodable, Sendable {
    /// `keep_sure` or `retry_after_repair`.
    let resolution: String
}

// MARK: - Uploading

/// How a record names the Wallet account it belongs to. Sure checks all
/// three against the connection before it takes the batch.
nonisolated struct WalletAccountKey: Encodable, Sendable, Equatable {
    let sourceAccountId: String
    let lineageId: String
    let mappingVersion: Int
}

/// One thing that happened in Wallet.
nonisolated enum WalletEvent: Encodable, Sendable, Equatable {
    nonisolated struct AccountRecord: Encodable, Sendable, Equatable {
        let sourceId: String
        let lineageId: String
        let mappingVersion: Int
        let displayName: String
        let institutionName: String
        let currency: String
        /// `asset` or `liability`.
        let kind: String
        var accountDescription: String?
        var openingDate: String?
    }

    nonisolated struct BalanceRecord: Encodable, Sendable, Equatable {
        let sourceId: String
        let sourceAccountId: String
        let lineageId: String
        let mappingVersion: Int
        /// `booked` or `available`.
        let kind: String
        let observedAt: String
        let money: WalletMoney
    }

    nonisolated struct TransactionRecord: Encodable, Sendable, Equatable {
        let sourceId: String
        let sourceAccountId: String
        let lineageId: String
        let mappingVersion: Int
        let amount: WalletMoney
        let transactionDescription: String
        let originalTransactionDescription: String
        let transactionType: String
        let status: String
        let transactedAt: String
        var postedAt: String?
        var merchantName: String?
        var merchantCategoryCode: Int?
        var foreignAmount: WalletMoney?
        var foreignExchangeRate: String?
    }

    nonisolated struct TombstoneRecord: Encodable, Sendable, Equatable {
        let sourceId: String
        let sourceAccountId: String
        let lineageId: String
        let mappingVersion: Int
    }

    case account(AccountRecord)
    /// The account is no longer shared with this app.
    case accountUnavailable(WalletAccountKey)
    case balance(BalanceRecord)
    case transaction(TransactionRecord)
    /// The transaction was removed from Wallet.
    case tombstone(TombstoneRecord)

    private enum CodingKeys: String, CodingKey {
        case kind, account, balance, transaction, tombstone
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .account(let record):
            try container.encode("account_upsert", forKey: .kind)
            try container.encode(record, forKey: .account)
        case .accountUnavailable(let key):
            try container.encode("account_unavailable", forKey: .kind)
            try key.encode(to: encoder)
        case .balance(let record):
            try container.encode("balance_upsert", forKey: .kind)
            try container.encode(record, forKey: .balance)
        case .transaction(let record):
            try container.encode("transaction_upsert", forKey: .kind)
            try container.encode(record, forKey: .transaction)
        case .tombstone(let record):
            try container.encode("transaction_tombstone", forKey: .kind)
            try container.encode(record, forKey: .tombstone)
        }
    }
}

/// One upload. Batches are numbered, and each carries the fingerprint of the
/// one before it, so Sure imports them in order and can tell if one is missing.
nonisolated struct WalletBatch: Encodable, Sendable {
    var protocolVersion = WalletWire.protocolVersion
    let connectionId: String
    let publisherId: String
    let generation: Int
    let streamId: String
    let batchId: String
    let sequence: Int
    /// Shared by the parts of one reading of Wallet that was too big for one batch.
    let captureId: String
    let chunkIndex: Int
    let chunkCount: Int
    /// `snapshot` for a full reading, `delta` for what changed since the last.
    let captureMode: String
    let snapshotComplete: Bool
    let capturedAt: String
    let selectedSourceAccountIds: [String]
    let events: [WalletEvent]
    /// Absent on the first batch of a stream.
    let predecessorDigest: String?
}

/// A batch that is written to disk and waiting to be uploaded.
nonisolated struct WalletQueuedBatch: Codable, Sendable, Equatable {
    let batchId: String
    let generation: Int
    let sequence: Int
    /// SHA-256 of the exact bytes on disk.
    let digest: String
    let recordCount: Int

    var fileName: String { "\(generation)-\(sequence).json" }
}

/// Where this phone's upload stream stands.
nonisolated struct WalletStreamPosition: Sendable, Equatable {
    let connectionId: String
    let publisherId: String
    let generation: Int
    let streamId: String
    let selectedSourceAccountIds: [String]
    /// The number the next batch will carry.
    var nextSequence: Int
    /// The fingerprint of the last batch made, nil before the first.
    var lastDigest: String?
}

nonisolated enum WalletSealer {
    nonisolated struct Sealed: Sendable {
        let batch: WalletQueuedBatch
        let payload: Data
    }

    /// Splits records into groups that each fit in one batch, by count and by size.
    static func chunks(
        _ events: [WalletEvent],
        maxRecords: Int = WalletWire.maxRecordsPerBatch,
        maxBytes: Int = WalletWire.maxBytesPerBatch
    ) throws -> [[WalletEvent]] {
        // Room for the batch's own fields around the records.
        let budget = max(maxBytes - 4096, 1024)
        var chunks: [[WalletEvent]] = []
        var current: [WalletEvent] = []
        var size = 0
        for event in events {
            let bytes = try WalletWire.encoder.encode(event).count + 1
            if !current.isEmpty, current.count >= maxRecords || size + bytes > budget {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(event)
            size += bytes
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Turns one reading of Wallet into numbered batches ready to upload, and
    /// moves `position` past them. No records gives no batches.
    static func seal(
        events: [WalletEvent],
        isSnapshot: Bool,
        capturedAt: Date,
        position: inout WalletStreamPosition,
        maxRecords: Int = WalletWire.maxRecordsPerBatch,
        maxBytes: Int = WalletWire.maxBytesPerBatch
    ) throws -> [Sealed] {
        let all = try chunks(events, maxRecords: maxRecords, maxBytes: maxBytes)
        let stamp = WalletWire.timestamp(capturedAt)
        var sealed: [Sealed] = []
        // Sure holds at most 100 parts of one capture, so a very large
        // reading goes up as several captures one after another.
        var start = 0
        while start < all.count {
            let capture = Array(all[start..<min(start + WalletWire.maxChunksPerCapture, all.count)])
            let captureID = WalletWire.newID()
            for (index, chunk) in capture.enumerated() {
                let batch = WalletBatch(
                    connectionId: position.connectionId,
                    publisherId: position.publisherId,
                    generation: position.generation,
                    streamId: position.streamId,
                    batchId: WalletWire.newID(),
                    sequence: position.nextSequence,
                    captureId: captureID,
                    chunkIndex: index,
                    chunkCount: capture.count,
                    captureMode: isSnapshot ? "snapshot" : "delta",
                    snapshotComplete: isSnapshot,
                    capturedAt: stamp,
                    selectedSourceAccountIds: position.selectedSourceAccountIds,
                    events: chunk,
                    predecessorDigest: position.lastDigest
                )
                let payload = try WalletWire.encoder.encode(batch)
                let digest = WalletWire.sha256(payload)
                sealed.append(Sealed(
                    batch: WalletQueuedBatch(
                        batchId: batch.batchId,
                        generation: batch.generation,
                        sequence: batch.sequence,
                        digest: digest,
                        recordCount: chunk.count
                    ),
                    payload: payload
                ))
                position.nextSequence += 1
                position.lastDigest = digest
            }
            start += capture.count
        }
        return sealed
    }
}
