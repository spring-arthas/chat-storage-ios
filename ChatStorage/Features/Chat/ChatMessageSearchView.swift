import SwiftUI

private enum ChatMessageSearchFilter: String, CaseIterable, Identifiable {
    case all
    case media
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .media: "照片与视频"
        case .files: "文件"
        }
    }
}

// [修改] 搜索结果固定限定当前好友会话，类型筛选只作用于服务端返回的这批结果。
struct ChatMessageSearchView: View {
    let friend: ChatFriend
    let repository: any ChatRepository
    let dynamicComposerRouteStore: DynamicComposerRouteStore
    let onOpenDynamicComposer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var selectedFilter: ChatMessageSearchFilter = .all
    @State private var messages: [ChatMessage] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var filteredMessages: [ChatMessage] {
        messages.filter { message in
            switch selectedFilter {
            case .all:
                return true
            case .media:
                if ["IMAGE", "VIDEO"].contains(message.msgType.uppercased()) { return true }
                return message.mixedContent?.attachments.contains(where: { $0.isImage || $0.isVideo }) == true
            case .files:
                if ["FILE", "AUDIO"].contains(message.msgType.uppercased()) { return true }
                return message.mixedContent?.attachments.contains(where: { !$0.isImage && !$0.isVideo }) == true
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("消息类型", selection: $selectedFilter) {
                    ForEach(ChatMessageSearchFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("chat.search.filters")

                Divider()

                Group {
                    if isSearching {
                        ProgressView("正在查找")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("查找失败", systemImage: "exclamationmark.magnifyingglass")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("重试") { Task { await search() } }
                        }
                    } else if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "查找聊天内容",
                            systemImage: "magnifyingglass",
                            description: Text("只查找你和\(friend.displayName)之间的消息")
                        )
                    } else if filteredMessages.isEmpty {
                        ContentUnavailableView.search(text: keyword)
                    } else {
                        List(filteredMessages) { message in
                            searchResultRow(message)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("查找聊天内容")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文字、文件名")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .accessibilityIdentifier("chat.search.screen")
        }
    }

    private func searchResultRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(message.isMine ? "我" : friend.displayName)
                    .font(.subheadline.bold())
                Spacer()
                Text(formattedTime(message.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.conversationSummary)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
            if let mixed = message.mixedContent, !mixed.attachments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: mixed.attachments.contains(where: { $0.isImage || $0.isVideo }) ? "photo.on.rectangle" : "doc")
                    Text(mixed.attachments.map(\.fileName).joined(separator: "、"))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                shareToDynamics(message)
            } label: {
                Label("分享到动态", systemImage: "quote.bubble")
            }
        }
        .accessibilityIdentifier("chat.search.result.\(message.id)")
    }

    private func search() async {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            messages = []
            errorMessage = nil
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            messages = try await repository.searchMessages(friendId: friend.friendId, keyword: normalized, limit: 100)
        } catch {
            messages = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "聊天内容搜索失败"
        }
    }

    private func shareToDynamics(_ message: ChatMessage) {
        let media = message.mixedContent?.attachments.map { attachment in
            DynamicMedia(
                kind: attachment.isImage ? .image : attachment.isVideo ? .video : .file,
                fileId: attachment.fileId,
                fileName: attachment.fileName,
                fileSize: attachment.fileSize,
                mimeType: attachment.mimeType
            )
        } ?? []
        dynamicComposerRouteStore.present(DynamicComposerDraft(reference: DynamicReference(
            sourceType: .chatMessage,
            sourceId: message.id,
            title: message.isMine ? "我发送的消息" : friend.displayName,
            subtitle: message.conversationSummary,
            media: media
        )))
        dismiss()
        onOpenDynamicComposer()
    }

    private func formattedTime(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
