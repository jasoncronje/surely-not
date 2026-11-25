import Foundation
import Observation

/// Something that stopped a Wallet action, in words for the person.
nonisolated struct WalletProblem: LocalizedError, Sendable, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }

    /// Sure's short error names, in plain words. Nil for a name with nothing
    /// better to say than the name itself.
    static func explain(code: String?) -> String? {
        switch code {
        case "publisher_forbidden":
            "Only an administrator of your Sure household can connect Apple Wallet."
        case "lineage_writer_conflict":
            "Sure still has another Wallet connection feeding this account, most likely from another phone. In Sure on the web, open Settings, then Bank sync, disconnect Apple Wallet, and try again."
        case "account_type_conflict":
            "That Sure account is a different kind of account or uses a different currency, so Wallet cannot feed it."
        case "account_already_supplied":
            "That Sure account is already kept up to date by another connection."
        case "lineage_account_conflict":
            "Two Wallet accounts cannot feed the same Sure account."
        case "account_forbidden":
            "You are no longer allowed to change one of the linked accounts in Sure."
        case "account_not_consented", "account_setup_required", "mapping_closed", "mapping_conflict":
            "Sure and this phone disagree about which accounts are connected. Disconnect Wallet and connect it again."
        case "connection_limit":
            "Your household has too many Wallet connections. Disconnect one in Sure first."
        case "connection_revoked":
            "Wallet was disconnected in Sure. Connect it again to carry on."
        case "inbox_full":
            "Sure is still working through earlier uploads. The rest will go up next time."
        case "invalid_timezone":
            "Sure does not know this phone's time zone."
        case "unsupported_protocol":
            "Your Sure server speaks a different version of Wallet sync than this app."
        default:
            nil
        }
    }

    /// Why a connection needs repairing.
    static func repair(_ reason: String) -> String {
        switch reason {
        case "conflict_retry_requested":
            "You asked Sure to take Wallet's version of a record. Repair the connection to send it again."
        case "stream_changed":
            "The connection was repaired somewhere else, so this phone has to start its uploads again."
        case "outbox_lost":
            "An upload that was waiting on this phone has gone missing."
        default:
            "Sure and this phone have fallen out of step (\(reason))."
        }
    }

    static func explain(_ error: any Error) -> String {
        if let error = error as? APIError, let known = explain(code: error.code) {
            return known
        }
        return error.localizedDescription
    }
}

nonisolated enum WalletSetup {
    /// How a Wallet account goes into Sure when Sure makes a new account for it.
    static func newAccountKind(for account: WalletAccount) -> (type: String, subtype: String, label: String) {
        if account.isLiability {
            return ("CreditCard", "credit_card", "Credit card")
        }
        let name = account.displayName.lowercased()
        if name.contains("saving") { return ("Depository", "savings", "Savings") }
        if name.contains("cash") { return ("Depository", "cash", "Cash") }
        return ("Depository", "checking", "Checking")
    }

    /// Sure only lets a Wallet account feed an account of the same kind and currency.
    static func canLink(_ account: WalletAccount, to target: Account) -> Bool {
        guard target.currency == account.currency, target.subtype?.isEmpty == false else { return false }
        return target.accountType == (account.isLiability ? "credit_card" : "depository")
    }

    /// What to ask of Sure for one Wallet account. `target` is the Sure
    /// account to feed, or nil for a new one. Nil when the two cannot be paired.
    static func mapping(
        for account: WalletAccount,
        target: Account?,
        booked: WalletBalance?,
        now: Date,
        timeZone: TimeZone
    ) -> WalletMappingRequest? {
        let institution = account.institutionName.trimmingCharacters(in: .whitespaces)
        let zone = timeZone.identifier.contains("/") ? timeZone.identifier : "Etc/UTC"
        if let target {
            guard canLink(account, to: target), let subtype = target.subtype else { return nil }
            return WalletMappingRequest(
                action: "link",
                name: WalletWire.clipped(account.title, to: 255),
                institutionName: institution.isEmpty ? "Apple Wallet" : WalletWire.clipped(institution, to: 255),
                currency: account.currency,
                accountableType: account.isLiability ? "CreditCard" : "Depository",
                subtype: subtype,
                ledgerTimezone: zone,
                accountId: target.id
            )
        }
        // A new account needs a balance to start from. Without a settled
        // one it starts at nothing and the first sync corrects it.
        let settled = booked.flatMap { balance -> WalletBalance? in
            balance.currency == account.currency ? balance : nil
        }
        let money = settled.flatMap { WalletMoney(amount: $0.amount, currency: $0.currency, isCredit: $0.isCredit) }
            ?? WalletMoney.zero(currency: account.currency)
        guard let money else { return nil }
        let kind = newAccountKind(for: account)
        return WalletMappingRequest(
            action: "create",
            name: WalletWire.clipped(account.title, to: 255),
            institutionName: institution.isEmpty ? "Apple Wallet" : WalletWire.clipped(institution, to: 255),
            currency: account.currency,
            accountableType: kind.type,
            subtype: kind.subtype,
            ledgerTimezone: zone,
            bookedBalance: money,
            observedAt: WalletWire.timestamp(min(settled?.observedAt ?? now, now))
        )
    }
}

/// One Wallet account picked during setup.
nonisolated struct WalletSetupChoice: Sendable, Equatable {
    let account: WalletAccount
    /// The Sure account to feed, or nil to have Sure make a new one.
    var target: Account?
}

/// Something Sure wants looked at, with the Wallet transaction it is about
/// when Wallet still has it.
nonisolated struct WalletReviewItem: Identifiable, Sendable, Equatable {
    let conflict: WalletConflict
    let transaction: WalletTransaction?

    var id: String { conflict.id }
}

/// Runs Apple Wallet sync: sets the connection up, reads what changed in
/// Wallet, queues it on disk and uploads it to Sure in order.
///
/// Every step can be repeated safely. Batches are written to disk before they
/// are sent, Sure treats a repeated batch as the same batch, and Wallet is
/// read from a saved place that only moves on once the batch is on disk.
@Observable
final class WalletSync {
    enum Availability: Equatable {
        case checking
        case ready
        /// Wallet sync cannot be used, and why.
        case unavailable(String)
    }

    @ObservationIgnored private let server: any WalletServer
    @ObservationIgnored private let uploader: any WalletUploading
    @ObservationIgnored private let source: any WalletSource
    @ObservationIgnored private let store: WalletStore
    @ObservationIgnored private let secrets: any WalletSecretStore
    @ObservationIgnored private let serverKey: String
    @ObservationIgnored private var draft: WalletDraft?
    @ObservationIgnored private var lastAutomaticSync: Date?

    private(set) var availability: Availability = .checking
    private(set) var link: WalletLink?
    /// The connection as Sure last described it.
    private(set) var connection: WalletConnection?
    private(set) var capabilities: WalletCapabilities?
    private(set) var isWorking = false
    /// What is happening right now, for the screen.
    private(set) var activity: String?
    /// Why the last action did not go through.
    private(set) var problem: String?
    /// What the last sync did.
    private(set) var lastOutcome: String?

    /// Called after Sure has been given new data, so open screens can reload.
    @ObservationIgnored var onImported: (() -> Void)?
    /// How long to wait between checks on whether Sure has imported an upload.
    @ObservationIgnored var settleDelay: Duration = .seconds(2)

    init(
        server: any WalletServer,
        uploader: any WalletUploading,
        source: any WalletSource,
        store: WalletStore,
        secrets: any WalletSecretStore,
        serverKey: String
    ) {
        self.server = server
        self.uploader = uploader
        self.source = source
        self.store = store
        self.secrets = secrets
        self.serverKey = serverKey
        let state = store.load()
        link = state.link
        draft = state.draft
    }

    convenience init(client: APIClient) {
        self.init(
            server: client,
            uploader: WalletUploader(baseURL: client.baseURL),
            source: FinanceKitSource(),
            store: WalletStore(serverURL: client.baseURL),
            secrets: WalletKeychain(),
            serverKey: WalletStore.key(for: client.baseURL)
        )
    }

    private var credentialKey: String { "\(serverKey).credential" }
    private var connectionKey: String { "\(serverKey).connection" }

    var isConnected: Bool { link != nil }
    /// Why uploads are stopped until the connection is repaired, if they are.
    var repairNeeded: String? { link?.repairReason.map(WalletProblem.repair) }
    var openConflicts: Int { connection?.openConflicts ?? 0 }
    var serverCanDiscard: Bool { capabilities?.canDiscard ?? false }

    func clearProblem() {
        problem = nil
    }

    // MARK: - Where things stand

    /// Checks that this phone and this server can do Wallet sync, and how the
    /// connection is doing.
    func refresh() async {
        if let reason = source.unavailableReason {
            availability = .unavailable(reason)
            return
        }
        do {
            let capabilities = try await server.walletCapabilities()
            guard capabilities.speaksThisProtocol else {
                availability = .unavailable(WalletProblem.explain(code: "unsupported_protocol") ?? "")
                return
            }
            self.capabilities = capabilities
            availability = .ready
        } catch is CancellationError {
            return
        } catch let error as APIError {
            // Once it has worked, a server that cannot be reached for a
            // moment does not take the feature away.
            if availability == .ready, error.status == nil { return }
            availability = .unavailable(Self.whyUnavailable(error))
            return
        } catch {
            availability = .unavailable(error.localizedDescription)
            return
        }
        // A sync in flight asks Sure itself once it has finished.
        if !isWorking {
            await refreshConnection()
        }
    }

    private static func whyUnavailable(_ error: APIError) -> String {
        if let known = WalletProblem.explain(code: error.code) { return known }
        switch error.status {
        case 404: return "Your Sure server does not support Apple Wallet yet. Update Sure, then try again."
        case 403: return "Your sign-in is not allowed to connect Wallet. An API key has to be able to read and write."
        default: return error.message
        }
    }

    private func refreshConnection() async {
        guard let connectionID = link?.connectionId else {
            connection = nil
            return
        }
        do {
            let current = try await server.walletConnection(id: connectionID)
            // The link may have moved on while Sure was answering.
            guard var link, link.connectionId == connectionID else { return }
            connection = current
            if current.isRevoked {
                forgetLink()
                problem = WalletProblem.explain(code: "connection_revoked")
                return
            }
            if current.needsRepair {
                link.repairReason = current.repairReason ?? "repair_required"
            } else if current.generation != link.generation
                || current.streamId.map({ $0.lowercased() != link.streamId.lowercased() }) == true {
                link.repairReason = "stream_changed"
            }
            self.link = link
            persist()
        } catch let error as APIError where error.status == 404 {
            guard link?.connectionId == connectionID else { return }
            forgetLink()
            problem = "Sure no longer has this Wallet connection. Connect Wallet again to carry on."
        } catch {
            // Not being able to ask is not news. The last answer stands.
        }
    }

    // MARK: - Setting up

    /// Asks Apple for the accounts to share and returns them. Apple shows its
    /// own sheet the first time. Nil when Wallet could not be read.
    func walletAccounts() async -> [WalletAccount]? {
        var accounts: [WalletAccount]?
        await work("Asking Wallet") {
            guard try await self.source.requestAuthorization() == .authorized else {
                throw WalletProblem("This app is not allowed to read Wallet. Allow it in the Settings app, then try again.")
            }
            accounts = try await self.source.accounts()
        }
        return accounts
    }

    /// Connects the chosen Wallet accounts to Sure, then runs the first sync.
    @discardableResult
    func connect(_ choices: [WalletSetupChoice], importSince: Date?) async -> Bool {
        let connected = await work("Connecting to Sure") {
            guard !choices.isEmpty else {
                throw WalletProblem("Choose at least one Wallet account.")
            }
            let balances = (try? await self.source.balances()) ?? []
            let now = Date.now
            var mappings: [String: WalletMappingRequest] = [:]
            for choice in choices {
                let booked = balances
                    .filter { $0.accountId == choice.account.id && $0.kind == .booked }
                    .max { $0.observedAt < $1.observedAt }
                guard let request = WalletSetup.mapping(
                    for: choice.account,
                    target: choice.target,
                    booked: booked,
                    now: now,
                    timeZone: .current
                ) else {
                    throw WalletProblem("\(choice.account.title) cannot feed \(choice.target?.name ?? "a new account") in Sure.")
                }
                mappings[choice.account.id] = request
            }
            var draft = WalletDraft(
                enrollment: WalletEnrollment(
                    enrollmentId: WalletWire.newID(),
                    consent: WalletConsent(
                        grantedAt: WalletWire.timestamp(now),
                        selectedSourceAccountIds: choices.map(\.account.id).sorted()
                    )
                ),
                accounts: choices.map(\.account),
                mappings: mappings,
                importSince: importSince
            )
            if let saved = self.draft, saved.matches(draft) {
                // The same request as an attempt that was cut short. Sure
                // picks it up where it stopped if it gets the same words.
                draft = saved
            } else if let abandoned = self.draft?.connectionId {
                try? await self.server.walletDisconnect(connectionID: abandoned, discard: false)
            }
            self.draft = draft
            self.persist()

            // A connection this phone made before, such as before the app
            // was deleted, would stop Sure from starting a new one.
            if let earlier = self.secrets.read(self.connectionKey), earlier != draft.connectionId {
                try? await self.server.walletDisconnect(connectionID: earlier, discard: false)
            }

            let enrolled = try await self.server.walletEnroll(draft.enrollment)
            draft.connectionId = enrolled.id
            self.draft = draft
            self.persist()
            self.secrets.write(enrolled.id, for: self.connectionKey)

            let configuration: WalletPublisherConfiguration
            switch enrolled.status {
            case "pending_mapping":
                for (sourceID, request) in draft.mappings.sorted(by: { $0.key < $1.key }) {
                    try await self.server.walletMap(connectionID: enrolled.id, sourceID: sourceID, request)
                }
                configuration = try await self.activate(enrolled.id)
            case "active":
                // It went live last time and the reply was lost.
                configuration = try await self.server.walletRenewCredential(connectionID: enrolled.id)
            default:
                self.draft = nil
                self.persist()
                throw WalletProblem("Sure closed that connection before it was finished. Try again.")
            }
            let mapped = (try? await self.server.walletMappings(connectionID: enrolled.id)) ?? []
            try self.adopt(configuration, draft: draft, mapped: mapped)
        }
        guard connected else { return false }
        await sync()
        return true
    }

    private func activate(_ connectionID: String) async throws -> WalletPublisherConfiguration {
        do {
            return try await server.walletActivate(connectionID: connectionID)
        } catch let error as APIError where error.code == "activation_conflict" {
            return try await server.walletRenewCredential(connectionID: connectionID)
        }
    }

    private func adopt(
        _ configuration: WalletPublisherConfiguration,
        draft: WalletDraft,
        mapped: [WalletMapping]
    ) throws {
        let chosen = Dictionary(draft.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = Dictionary(mapped.map { ($0.sourceId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = configuration.accountBindings.compactMap { binding -> WalletLinkedAccount? in
            let id = binding.sourceAccountId.lowercased()
            guard let account = chosen[id] else { return nil }
            return WalletLinkedAccount(
                sourceId: id,
                lineageId: binding.lineageId,
                mappingVersion: binding.mappingVersion,
                name: account.title,
                currency: account.currency,
                isLiability: account.isLiability,
                sureAccountId: targets[id]?.accountId
            )
        }
        guard !accounts.isEmpty, accounts.count == configuration.accountBindings.count else {
            throw WalletProblem("Sure connected different accounts than the ones chosen. Disconnect Wallet in Sure and try again.")
        }
        secrets.write(configuration.publisherCredential, for: credentialKey)
        link = WalletLink(
            connectionId: configuration.id,
            publisherId: configuration.publisherId,
            generation: configuration.generation,
            streamId: configuration.streamId,
            nextSequence: configuration.nextSequence,
            accounts: accounts,
            importSince: draft.importSince,
            // A stream that has already taken batches this phone knows
            // nothing of cannot be carried on. It has to start again.
            repairReason: configuration.nextSequence == 1 ? nil : "stream_changed",
            maxRecords: configuration.maxRecordsPerBatch ?? WalletWire.maxRecordsPerBatch,
            maxBytes: configuration.maxBytesPerBatch ?? WalletWire.maxBytesPerBatch
        )
        self.draft = nil
        connection = nil
        persist()
    }

    // MARK: - Syncing

    /// Syncs when the app comes to the front, at most every fifteen minutes.
    /// Never puts Apple's permission sheet in front of the person.
    func syncIfDue(now: Date = .now) async {
        guard link != nil, !isWorking else { return }
        if let last = lastAutomaticSync, now.timeIntervalSince(last) < 15 * 60 { return }
        lastAutomaticSync = now
        if availability != .ready {
            await refresh()
        }
        await sync(askingForAccess: false)
    }

    /// Reads what changed in Wallet and uploads it.
    @discardableResult
    func sync(askingForAccess: Bool = true) async -> Bool {
        guard availability == .ready, let link, link.repairReason == nil else { return false }
        var sent = 0
        let finished = await work("Reading Wallet") {
            try await self.capture(askingForAccess: askingForAccess)
            sent = try await self.upload()
            await self.settle(sent: sent)
        }
        guard finished else {
            // What the sync before this one did is no longer the news.
            lastOutcome = nil
            return false
        }
        self.link?.lastSyncedAt = .now
        persist()
        lastOutcome = sent == 0 ? "Nothing new in Wallet."
            : "Sent \(sent) \(sent == 1 ? "record" : "records") to Sure."
        if sent > 0 {
            onImported?()
        }
        return true
    }

    /// Reads Wallet and queues what changed as batches on disk.
    private func capture(askingForAccess: Bool) async throws {
        // With that much still waiting there is no point reading more.
        guard var link, link.outbox.count < WalletWire.maxChunksPerCapture else { return }
        var access = try await source.authorization()
        if access == .notAsked, askingForAccess {
            access = try await source.requestAuthorization()
        }
        guard access == .authorized else {
            throw WalletProblem("This app is not allowed to read Wallet. Allow it in the Settings app, then try again.")
        }

        var reading = WalletReading()
        reading.accounts = try await source.accounts()
        reading.balances = try await source.balances()
        let shared = Set(reading.accounts.map(\.id))
        for account in link.accounts where shared.contains(account.sourceId) {
            var token = account.historyToken
            let changes: WalletTransactionChanges
            do {
                changes = try await source.transactionChanges(accountId: account.sourceId, since: token)
            } catch WalletSourceError.historyExpired {
                token = nil
                changes = try await source.transactionChanges(accountId: account.sourceId, since: nil)
            }
            if token == nil {
                reading.readInFull.insert(account.sourceId)
            }
            reading.transactions[account.sourceId] = changes
        }

        // Sure refuses a capture older than the last one it imported.
        let capturedAt = WalletWire.wholeMilliseconds(max(.now, link.lastCapturedAt ?? .distantPast))
        let plan = WalletCapture.plan(
            accounts: link.accounts,
            reading: reading,
            importSince: link.importSince,
            capturedAt: capturedAt
        )
        var position = link.position
        let sealed = try WalletSealer.seal(
            events: plan.events,
            // Leaving out older transactions makes it less than the whole picture.
            isSnapshot: plan.isSnapshot && link.importSince == nil,
            capturedAt: capturedAt,
            position: &position,
            maxRecords: link.maxRecords,
            maxBytes: link.maxBytes
        )
        for item in sealed {
            try store.writePayload(item.payload, for: item.batch)
        }
        // Only now, with the batches safely on disk, does the saved place
        // in Wallet's history move on.
        link.accounts = plan.accounts
        link.nextSequence = position.nextSequence
        link.lastDigest = position.lastDigest
        link.outbox += sealed.map(\.batch)
        if !sealed.isEmpty {
            link.lastCapturedAt = capturedAt
        }
        self.link = link
        try save()
    }

    /// Sends the waiting batches, oldest first. Returns how many records went up.
    private func upload() async throws -> Int {
        guard var link else { return 0 }
        let total = link.outbox.count
        var sent = 0
        var renewed = false
        while let batch = link.outbox.first {
            guard let payload = store.payload(for: batch) else {
                try stop(&link, reason: "outbox_lost")
            }
            guard let credential = secrets.read(credentialKey) else {
                guard !renewed else { throw WalletProblem("Sure would not give this phone a new upload key.") }
                renewed = true
                try await renewCredential()
                link = self.link ?? link
                continue
            }
            activity = total > 1 ? "Uploading \(total - link.outbox.count + 1) of \(total)" : "Uploading"
            let result = await uploader.upload(
                payload,
                batch: batch,
                publisherId: link.publisherId,
                credential: credential
            )
            switch result {
            case .accepted(let receipt):
                link.outbox.removeFirst()
                link.lastUploadedSequence = batch.sequence
                store.removePayload(for: batch)
                sent += batch.recordCount
                self.link = link
                persist()
                if receipt.wasDropped {
                    try stop(&link, reason: receipt.errorCode ?? "batch_\(receipt.status)")
                }
            case .unreachable(let why):
                throw WalletProblem("Could not reach the server. \(why)")
            case .refused(401, _):
                // The key was swapped or the connection was closed.
                guard !renewed else { throw WalletProblem("Sure did not accept this phone's upload key.") }
                renewed = true
                secrets.write(nil, for: credentialKey)
                try await renewCredential()
                link = self.link ?? link
            case .refused(429, _), .refused(503, _):
                throw WalletProblem(WalletProblem.explain(code: "inbox_full") ?? "")
            case .refused(403, let code) where code != "repair_required":
                if code == "connection_revoked" {
                    forgetLink()
                }
                throw WalletProblem(WalletProblem.explain(code: code) ?? "Sure refused the upload (\(code ?? "403")).")
            case .refused(let status, let code):
                // Sure will not take this batch as it is, now or later, so
                // the stream has to start again.
                try stop(&link, reason: code ?? "upload_refused_\(status)")
            }
        }
        return sent
    }

    /// Marks the connection as needing repair and stops the sync.
    private func stop(_ link: inout WalletLink, reason: String) throws -> Never {
        link.repairReason = reason
        self.link = link
        persist()
        throw WalletProblem(WalletProblem.repair(reason))
    }

    /// Gets a new upload key, as long as the connection is still good.
    private func renewCredential() async throws {
        await refreshConnection()
        guard let link else {
            throw WalletProblem(problem ?? WalletProblem.explain(code: "connection_revoked") ?? "")
        }
        if let reason = link.repairReason {
            throw WalletProblem(WalletProblem.repair(reason))
        }
        let configuration = try await server.walletRenewCredential(connectionID: link.connectionId)
        secrets.write(configuration.publisherCredential, for: credentialKey)
    }

    /// Sure imports uploads in the background. This waits a short while for
    /// it, so the rest of the app can show the new data straight away.
    private func settle(sent: Int) async {
        guard let link else { return }
        guard sent > 0 else {
            await refreshConnection()
            return
        }
        activity = "Waiting for Sure"
        for _ in 0..<6 {
            guard let current = try? await server.walletConnection(id: link.connectionId) else { return }
            connection = current
            if current.needsRepair {
                self.link?.repairReason = current.repairReason ?? "repair_required"
                persist()
                return
            }
            if (current.nextSequence ?? 0) > link.lastUploadedSequence { return }
            guard (try? await Task.sleep(for: settleDelay)) != nil else { return }
        }
    }

    // MARK: - Repairing and disconnecting

    /// Starts the upload stream again from nothing and sends Wallet in full.
    /// Sure matches what it already has, so nothing is doubled.
    func repair() async {
        guard let connectionID = link?.connectionId else { return }
        let repaired = await work("Repairing the connection") {
            let configuration: WalletPublisherConfiguration
            do {
                configuration = try await self.server.walletRepair(connectionID: connectionID)
            } catch let error as APIError where error.code == "connection_revoked" {
                self.forgetLink()
                throw error
            }
            guard var link = self.link else { return }
            let bindings = Dictionary(
                configuration.accountBindings.map { ($0.sourceAccountId.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.store.clearOutbox()
            link.generation = configuration.generation
            link.streamId = configuration.streamId
            link.nextSequence = configuration.nextSequence
            link.lastDigest = nil
            link.outbox = []
            link.lastUploadedSequence = 0
            link.repairReason = nil
            link.accounts = link.accounts.map { account in
                var account = account
                account.historyToken = nil
                account.sentAccount = nil
                account.sentBalances = [:]
                account.reportedUnavailable = false
                if let binding = bindings[account.sourceId] {
                    account.lineageId = binding.lineageId
                    account.mappingVersion = binding.mappingVersion
                }
                return account
            }
            self.secrets.write(configuration.publisherCredential, for: self.credentialKey)
            self.link = link
            try self.save()
        }
        if repaired {
            await sync()
        }
    }

    /// Stops Wallet sync. `removingImported` also takes what it imported out of Sure.
    func disconnect(removingImported: Bool) async {
        guard let connectionID = link?.connectionId else { return }
        let done = await work("Disconnecting") {
            do {
                try await self.server.walletDisconnect(connectionID: connectionID, discard: removingImported)
            } catch let error as APIError where error.status == 404 {
                // Already gone from Sure.
            }
            self.forgetLink()
            self.secrets.write(nil, for: self.connectionKey)
        }
        if done {
            lastOutcome = nil
            onImported?()
        }
    }

    private func forgetLink() {
        store.clearOutbox()
        secrets.write(nil, for: credentialKey)
        link = nil
        connection = nil
        persist()
    }

    // MARK: - Records Sure wants looked at

    func reviewItems() async throws -> [WalletReviewItem] {
        guard let connectionID = link?.connectionId else { return [] }
        let conflicts = try await server.walletConflicts(connectionID: connectionID)
        let ids = Set(conflicts.compactMap(\.sourceID))
        let found = (try? await source.transactions(ids: ids)) ?? []
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return conflicts.map { conflict in
            WalletReviewItem(conflict: conflict, transaction: conflict.sourceID.flatMap { byID[$0] })
        }
    }

    /// Settles records by keeping what Sure has, or by asking for Wallet's
    /// version, which needs a repair before it arrives.
    @discardableResult
    func resolve(_ conflicts: [WalletConflict], keepingSure: Bool) async -> Bool {
        guard let connectionID = link?.connectionId else { return false }
        let done = await work("Saving your choice") {
            for conflict in conflicts {
                try await self.server.walletResolve(
                    connectionID: connectionID,
                    conflictID: conflict.id,
                    keepSure: keepingSure
                )
            }
        }
        await refreshConnection()
        return done
    }

    // MARK: - Plumbing

    /// Runs one action at a time and turns a failure into `problem`.
    @discardableResult
    private func work(_ label: String, _ body: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        activity = label
        problem = nil
        defer {
            isWorking = false
            activity = nil
        }
        do {
            try await body()
            return true
        } catch is CancellationError {
            return false
        } catch {
            problem = WalletProblem.explain(error)
            return false
        }
    }

    private func save() throws {
        try store.save(WalletState(link: link, draft: draft))
    }

    private func persist() {
        try? save()
    }
}
