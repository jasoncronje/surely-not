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
        bubbles = (chat.messages ?? []).map {
            Bubble(id: $0.id, isUser: $0.isUser, text: $0.content ?? "")
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

    init(client: APIClient, chatID: String?, title: String) {
        _model = State(initialValue: ChatModel(client: client, chatID: chatID))
        self.title = title
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.isTruncated {
                    Text("This is a long chat. Only its first messages can be shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.bubbles) { bubble in
                    BubbleView(bubble: bubble)
                }
                if model.isWaitingForReply {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.subheadline)
                }
                if let error = model.replyError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        if model.canRetry {
                            Button("Try again") {
                                Task { await model.retry() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.isLoading {
                ProgressView()
            } else if let error = model.loadError {
                ContentUnavailableView(
                    "Could not load this chat",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.bubbles.isEmpty {
                ContentUnavailableView(
                    "Ask about your money",
                    systemImage: "sparkles",
                    description: Text("For example: how much did I spend on food last month?")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background.secondary, in: .rect(cornerRadius: 20))
            Button("Send", systemImage: "arrow.up.circle.fill") {
                let text = draft
                draft = ""
                Task { await model.send(text) }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 32))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWaitingForReply)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct BubbleView: View {
    let bubble: ChatModel.Bubble

    /// Replies use Markdown for bold, links and the like. Block layout such as
    /// tables is shown as plain text.
    private var text: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: bubble.text, options: options)) ?? AttributedString(bubble.text)
    }

    var body: some View {
        HStack {
            if bubble.isUser { Spacer(minLength: 40) }
            Text(bubble.isUser ? AttributedString(bubble.text) : text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(bubble.isUser ? Color.white : Color.primary)
                .background(
                    bubble.isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary),
                    in: .rect(cornerRadius: 18)
                )
            if !bubble.isUser { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bubble.isUser ? "You: \(bubble.text)" : "Assistant: \(bubble.text)")
    }
}
