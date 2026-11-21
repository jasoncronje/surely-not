import Observation
import SwiftUI

@Observable
final class ChatListModel {
    private let client: APIClient

    var chats: Loadable<[Chat]> = .loading
    var actionError: String?

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        chats = await .fetching(keeping: chats) { try await client.chats() }
    }

    func delete(_ chat: Chat) async {
        await perform { try await self.client.deleteChat(id: chat.id) }
    }

    func rename(_ chat: Chat, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try await self.client.renameChat(id: chat.id, title: trimmed) }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }
}

/// Where a row or the compose button leads.
enum ChatRoute: Hashable {
    case new
    case existing(id: String, title: String)
}

struct ChatListView: View {
    private let client: APIClient
    @State private var model: ChatListModel
    @State private var path: [ChatRoute] = []
    @State private var renaming: Chat?
    @State private var newTitle = ""

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: ChatListModel(client: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                LoadableView(state: model.chats, retry: model.load) { chats in
                    if chats.isEmpty {
                        ContentUnavailableView(
                            "No chats yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Ask a question about your money to start one.")
                        )
                    }
                    ForEach(chats) { chat in
                        NavigationLink(value: ChatRoute.existing(id: chat.id, title: chat.title)) {
                            ChatRow(chat: chat)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(chat) }
                            }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                newTitle = chat.title
                                renaming = chat
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        path.append(.new)
                    }
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .new:
                    ChatView(client: client, chatID: nil, title: "New chat")
                case .existing(let id, let title):
                    ChatView(client: client, chatID: id, title: title)
                }
            }
            .alert("Rename chat", isPresented: renameShown) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let chat = renaming {
                        Task { await model.rename(chat, to: newTitle) }
                    }
                }
            }
            .alert("That did not work", isPresented: actionErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
            .refreshable { await model.load() }
            // Reloads on every return from a chat, so new chats and titles show up.
            .onAppear {
                Task { await model.load() }
            }
        }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

private struct ChatRow: View {
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.title)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let date = chat.lastMessageAt {
                    Text(date, format: .relative(presentation: .named))
                }
                if chat.hasError {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
