import Observation
import SwiftUI

/// Paces how a reply is typed onto the screen.
///
/// Sure's API does not stream. The app fetches the reply in whole chunks, so
/// without this a long answer would pop in all at once. Each step shows a
/// little more: slowly when little is waiting, faster when a lot is, so the
/// screen catches up with the server within a few seconds.
nonisolated enum TextReveal {
    /// Steps per second.
    static let rate = 30.0

    /// How many characters to show after one more step.
    static func nextCount(current: Int, text: String) -> Int {
        let total = text.count
        guard current < total else { return total }
        let step = max(2, (total - current) / 25)
        var next = min(current + step, total)
        // Finish the word in progress, so words and Markdown marks are not
        // shown half-written.
        var index = text.index(text.startIndex, offsetBy: next)
        var extended = 0
        while index < text.endIndex, !text[index].isWhitespace, extended < 16 {
            index = text.index(after: index)
            next += 1
            extended += 1
        }
        return next
    }
}

@Observable
final class ChatModel {
    /// A message as shown on screen.
    struct Bubble: Identifiable {
        let id: String
        let isUser: Bool
        let text: String
    }

    private let client: APIClient
    private(set) var chatID: String?

    var bubbles: [Bubble] = []
    var isLoading: Bool
    var isWaitingForReply = false
    var isTruncated = false
    var loadError: String?
    /// A failed send or a failed AI reply. Offers a retry when the server has one.
    var replyError: String?
    var canRetry = false

    /// The reply being typed onto the screen, and how much of it shows so far.
    private(set) var revealingID: String?
    private(set) var revealedCount = 0
    private var revealTask: Task<Void, Never>?
    /// Messages that were already on screen when the last message was sent.
    /// Only a reply that is not in here gets typed out.
    private var idsBeforeSend: Set<String> = []

    /// True until the first words of a reply are on screen.
    var isThinking: Bool {
        isWaitingForReply && revealedCount == 0
    }

    /// The text to draw for a bubble: all of it, or the part typed so far.
    func visibleText(for bubble: Bubble) -> String {
        bubble.id == revealingID ? String(bubble.text.prefix(revealedCount)) : bubble.text
    }

    init(client: APIClient, chatID: String?) {
        self.client = client
        self.chatID = chatID
        isLoading = chatID != nil
    }

    func load() async {
        guard let chatID, !isWaitingForReply else { return }
        do {
            apply(try await client.chat(id: chatID))
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            if bubbles.isEmpty { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    func send(_ text: String) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isWaitingForReply else { return }
        let countBefore = bubbles.count
        beginExpectingReply()
        bubbles.append(Bubble(id: "pending-\(UUID().uuidString)", isUser: true, text: content))
        replyError = nil
        isWaitingForReply = true
        defer { isWaitingForReply = false }
        do {
            if let chatID {
                try await client.sendMessage(chatID: chatID, content: content)
            } else {
                chatID = try await client.createChat(firstMessage: content).id
            }
            try await waitForReply(after: countBefore + 1)
        } catch is CancellationError {
            return
        } catch {
            canRetry = false
            replyError = error.localizedDescription
        }
    }

    func retry() async {
        guard let chatID, !isWaitingForReply else { return }
        replyError = nil
        beginExpectingReply()
        isWaitingForReply = true
        defer { isWaitingForReply = false }
        do {
            try await client.retryLastMessage(chatID: chatID)
            try await waitForReply(after: bubbles.count)
        } catch is CancellationError {
            return
        } catch {
            replyError = error.localizedDescription
        }
    }

    /// Sure does not stream replies over this API, so the app checks the chat
    /// every second. The server may fill a reply in gradually, so it counts as
    /// finished once its text has stayed the same for two checks in a row.
    /// Gives up after two minutes.
    private func waitForReply(after messageCount: Int) async throws {
        guard let chatID else { return }
        var lastSeenReply: String?
        var unchangedChecks = 0
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            let chat = try await client.chat(id: chatID)
            apply(chat)
            if chat.hasError {
                canRetry = true
                replyError = chat.error?.text ?? "The assistant could not answer."
                return
            }
            guard bubbles.count > messageCount, let last = bubbles.last, !last.isUser else {
                continue
            }
            if last.text == lastSeenReply {
                unchangedChecks += 1
                if unchangedChecks >= 2 { return }
            } else {
                lastSeenReply = last.text
                unchangedChecks = 0
            }
        }
        canRetry = false
        replyError = "The assistant is taking a long time. Pull down to check again."
    }

    private func beginExpectingReply() {
        revealTask?.cancel()
        revealingID = nil
        revealedCount = 0
        idsBeforeSend = Set(bubbles.map(\.id))
    }

    private func apply(_ chat: Chat) {
        // The server creates the reply before it has any text. Leaving that
        // out keeps an empty bubble from showing while "Thinking" is on screen.
        bubbles = (chat.messages ?? []).compactMap { message in
            let text = message.content ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return Bubble(id: message.id, isUser: message.isUser, text: text)
        }
        isTruncated = chat.isTruncated
        if chat.hasError, !isWaitingForReply {
            canRetry = true
            replyError = chat.error?.text ?? "The assistant could not answer."
        }
        if isWaitingForReply, revealingID == nil,
           let reply = bubbles.last, !reply.isUser, !idsBeforeSend.contains(reply.id) {
            startRevealing(reply.id)
        }
    }

    /// Types the reply out a little at a time. Keeps going while the server
    /// may still add text, and stops once everything received is on screen.
    private func startRevealing(_ id: String) {
        revealingID = id
        revealedCount = 0
        revealTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / TextReveal.rate))
                guard let self, !Task.isCancelled, self.revealingID == id,
                      let text = self.bubbles.first(where: { $0.id == id })?.text else { return }
                if self.revealedCount < text.count {
                    self.revealedCount = TextReveal.nextCount(current: self.revealedCount, text: text)
                } else if !self.isWaitingForReply {
                    self.revealingID = nil
                    return
                }
            }
        }
    }
}

struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    private let title: String

    private static let starters = [
        "How much did I spend on food last month?",
        "What changed most in my spending this month?",
        "Which subscriptions am I paying for?",
    ]

    init(client: APIClient, chatID: String?, title: String) {
        _model = State(initialValue: ChatModel(client: client, chatID: chatID))
        self.title = title
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.isLoading {
                    Card {
                        LoadingLines(count: 4)
                    }
                } else if let error = model.loadError {
                    Card {
                        Text("Could not load this chat. \(error)")
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                        Button("Try again") {
                            Task { await model.load() }
                        }
                        .font(Theme.smallStrong)
                        .foregroundStyle(Theme.text)
                    }
                } else if model.bubbles.isEmpty {
                    starterList
                }
                if model.isTruncated {
                    Text("This is a long chat. Only its first messages can be shown.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
                ForEach(model.bubbles) { bubble in
                    let text = model.visibleText(for: bubble)
                    if !text.isEmpty {
                        BubbleView(isUser: bubble.isUser, text: text)
                    }
                }
                if model.isThinking {
                    ThinkingIndicator()
                }
                if let error = model.replyError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(Theme.small)
                            .foregroundStyle(Theme.negative)
                        if model.canRetry {
                            Button("Try again") {
                                Task { await model.retry() }
                            }
                            .font(Theme.smallStrong)
                            .foregroundStyle(Theme.text)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    /// Questions to start from, so a new chat is never a blank page.
    private var starterList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about your money")
                .font(Theme.section)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(Self.starters.enumerated()), id: \.offset) { index, starter in
                    if index > 0 {
                        RowRule().padding(.leading, 16)
                    }
                    Button {
                        send(starter)
                    } label: {
                        Text(starter)
                            .font(Theme.body)
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isWaitingForReply
    }

    private func send(_ text: String) {
        draft = ""
        Task { await model.send(text) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .font(Theme.body)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.surface, in: .rect(cornerRadius: 22))
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.primary, in: .circle)
            }
            .accessibilityLabel("Send")
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 8)
        .background(Theme.ground)
    }
}

private struct BubbleView: View {
    let isUser: Bool
    let text: String

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.onPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.primary, in: .rect(cornerRadius: Theme.cardRadius))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
        } else {
            // Replies take the full width, so their tables have room.
            MarkdownView(text)
                .textSelection(.enabled)
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Assistant: \(text)")
        }
    }
}

/// Shown while a reply is on its way: the app's mark drawing itself over and
/// over, in the place the reply will appear. First the tick, then the stroke
/// through it, then it fades and starts again.
private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one full loop.
    private static let loop = 1.9

    var body: some View {
        HStack(spacing: 10) {
            if reduceMotion {
                ProductMark(size: 22)
            } else {
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.loop)
                    DrawnMark(
                        tick: Self.eased((time - 0.05) / 0.5),
                        strike: Self.eased((time - 0.6) / 0.3),
                        opacity: 1 - Self.eased((time - 1.45) / 0.4)
                    )
                }
                .frame(width: 22, height: 22)
            }
            Text("Thinking")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The assistant is thinking")
    }

    /// Clamps to 0...1 and eases in and out.
    private static func eased(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The app's mark with each stroke drawn part of the way.
private struct DrawnMark: View {
    let tick: Double
    let strike: Double
    let opacity: Double

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 24
            var tickPath = Path()
            tickPath.move(to: CGPoint(x: 3.5 * unit, y: 12.5 * unit))
            tickPath.addLine(to: CGPoint(x: 9.5 * unit, y: 18.5 * unit))
            tickPath.addLine(to: CGPoint(x: 20.5 * unit, y: 5.5 * unit))
            var strikePath = Path()
            strikePath.move(to: CGPoint(x: 11.5 * unit, y: 5 * unit))
            strikePath.addLine(to: CGPoint(x: 20.5 * unit, y: 16 * unit))
            let style = StrokeStyle(lineWidth: 2.8 * unit, lineCap: .round, lineJoin: .round)
            // The finished shape sits faintly behind, so the mark never vanishes.
            context.stroke(tickPath, with: .color(Theme.track), style: style)
            context.stroke(strikePath, with: .color(Theme.track), style: style)
            context.opacity = opacity
            if tick > 0 {
                context.stroke(tickPath.trimmedPath(from: 0, to: tick), with: .color(Theme.accent), style: style)
            }
            if strike > 0 {
                context.stroke(strikePath.trimmedPath(from: 0, to: strike), with: .color(Theme.accent), style: style)
            }
        }
        .accessibilityHidden(true)
    }
}
