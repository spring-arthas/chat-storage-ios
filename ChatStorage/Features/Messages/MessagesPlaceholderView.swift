import SwiftUI

struct MessagesPlaceholderView: View {
    @State private var model: MessagesViewModel
    private let sampleMode: Bool

    init(repository: any FriendRepository, sampleMode: Bool) {
        _model = State(initialValue: MessagesViewModel(
            repository: repository,
            initialFriends: sampleMode ? PreviewFriends.all : []
        ))
        self.sampleMode = sampleMode
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.visibleFriends.isEmpty && !model.isRefreshing {
                    ContentUnavailableView(
                        model.searchText.isEmpty ? "暂无好友" : "没有匹配结果",
                        systemImage: "person.2",
                        description: Text(model.searchText.isEmpty ? "下拉刷新好友列表。" : "请尝试其他关键词。")
                    )
                } else {
                    friendList
                }
            }
            .navigationTitle("消息")
            .searchable(text: $model.searchText, prompt: "搜索好友或消息")
            .navigationDestination(for: ChatFriend.self) { routedFriend in
                let current = model.friends.first(where: { $0.friendId == routedFriend.friendId }) ?? routedFriend
                ChatConversationView(
                    friend: current,
                    isUpdatingPin: model.isUpdatingPin(for: current),
                    onTogglePin: { await model.togglePin(current) }
                )
            }
            .task {
                if !sampleMode && model.friends.isEmpty { await model.refresh() }
            }
            .alert("操作失败", isPresented: errorIsPresented) {
                Button("知道了") { model.clearError() }
            } message: {
                Text(model.errorMessage ?? "请稍后重试")
            }
        }
    }

    private var friendList: some View {
        List {
            let pinned = model.visibleFriends.filter(\.isPinned)
            let recent = model.visibleFriends.filter { !$0.isPinned }
            if !pinned.isEmpty {
                Section("置顶") { rows(pinned) }
            }
            if !recent.isEmpty {
                Section(pinned.isEmpty ? "好友" : "最近消息") { rows(recent) }
            }
        }
        .accessibilityIdentifier("friends.list")
        .refreshable { await model.refresh() }
        .overlay {
            if model.isRefreshing && model.friends.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private func rows(_ friends: [ChatFriend]) -> some View {
        ForEach(friends) { friend in
            NavigationLink(value: friend) {
                FriendConversationRow(friend: friend)
            }
            .accessibilityIdentifier("conversation.\(friend.friendId)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Task { await model.togglePin(friend) }
                } label: {
                    Label(friend.isPinned ? "取消置顶" : "置顶", systemImage: friend.isPinned ? "pin.slash" : "pin")
                }
                .tint(AppTheme.primaryGreen)
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )
    }
}

private struct FriendConversationRow: View {
    let friend: ChatFriend

    var body: some View {
        HStack(spacing: 13) {
            FriendAvatarView(friend: friend, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(friend.displayName).font(.headline)
                    if friend.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(friend.latestMessage ?? (friend.isOnline ? "在线" : "开始聊天"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if friend.unreadCount > 0 {
                Text("\(friend.unreadCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AppTheme.primaryGreen, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}
