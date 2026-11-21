import Observation
import SwiftUI

@Observable
final class ChatModel {
    /// A message as shown on screen. `pending` ones were typed here and have
    /// not come back from the server yet.
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
    /// every two seconds. The reply is treated as finished once it has text
    /// that did not change between two checks, because the server fills it in
    /// gradually. Gives up after two minutes.
    private func waitForReply(after messageCount: Int) async throws {
        guard let chatID else { return }
        var lastSeenReply: String?
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let chat = try await client.chat(id: chatID)
            apply(chat)
            if chat.hasError {
                canRetry = true
                replyError = chat.error?.text ?? "The assistant could not answer."
                return
            }
            guard bubbles.count > messageCount, let last = bubbles.last, !last.isUser, !last.text.isEmpty else {
                continue
            }
            if last.text == lastSeenReply { return }
            lastSeenReply = last.text
        }
        canRetry = false
        replyError = "The assistant is taking a long time. Pull down to check again."
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
                    BubbleView(bubble: bubble)
                }
                if model.isWaitingForReply {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking")
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 4)
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
    let bubble: ChatModel.Bubble

    var body: some View {
        if bubble.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(bubble.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.onPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.primary, in: .rect(cornerRadius: Theme.cardRadius))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(bubble.text)")
        } else {
            // Replies take the full width, so their tables have room.
            MarkdownView(bubble.text)
                .textSelection(.enabled)
                .padding(Theme.cardPadding)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Assistant: \(bubble.text)")
        }
    }
}
