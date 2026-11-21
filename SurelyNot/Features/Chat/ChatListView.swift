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
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    ScreenHeader(title: "Chat") {
                        Button("New chat", systemImage: "plus") {
                            path.append(.new)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(.top, 8)
                    LoadableView(state: model.chats, placeholderLines: 4, retry: model.load) { chats in
                        if chats.isEmpty {
                            Card {
                                EmptyNote(text: "No chats yet. Start one to ask about your spending, accounts or budget.")
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                                    if index > 0 {
                                        RowRule().padding(.leading, 16)
                                    }
                                    row(chat)
                                }
                            }
                            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                            .clipShape(.rect(cornerRadius: Theme.cardRadius))
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
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

    private func row(_ chat: Chat) -> some View {
        HStack(spacing: 4) {
            NavigationLink(value: ChatRoute.existing(id: chat.id, title: chat.title)) {
                ChatRow(chat: chat)
            }
            .buttonStyle(RowButtonStyle())
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newTitle = chat.title
                    renaming = chat
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await model.delete(chat) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More for \(chat.title)")
            .padding(.trailing, 4)
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
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let date = chat.lastMessageAt {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(Theme.muted)
                }
                if chat.hasError {
                    Text("Reply failed")
                        .foregroundStyle(Theme.negative)
                }
            }
            .font(Theme.small)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.leading, 16)
        .contentShape(.rect)
    }
}
