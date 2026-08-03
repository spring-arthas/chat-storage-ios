import PhotosUI
import SwiftUI

struct ChatConversationView: View {
    let friend: ChatFriend
    let isUpdatingPin: Bool
    let onTogglePin: () async -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var backgroundData: Data?
    @State private var draft = ""
    private let backgroundStore = ChatBackgroundStore.shared

    var body: some View {
        ZStack {
            ChatBackgroundView(imageData: backgroundData)
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text("今天")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    sampleBubble("背景现在会完整填满聊天区域。", mine: false)
                    sampleBubble("并且保留系统左滑返回。", mine: true)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityIdentifier("chat.conversation.screen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink {
                    FriendDetailView(friend: friend)
                } label: {
                    HStack(spacing: 9) {
                        FriendAvatarView(friend: friend, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friend.displayName).font(.headline)
                            Text(friend.isOnline ? "在线" : "离线").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.friend.avatar")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await onTogglePin() }
                    } label: {
                        Label(friend.isPinned ? "取消置顶" : "置顶聊天", systemImage: friend.isPinned ? "pin.slash" : "pin")
                    }
                    .disabled(isUpdatingPin)
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("更换聊天背景", systemImage: "photo")
                    }
                    if backgroundData != nil {
                        Button(role: .destructive) {
                            Task {
                                try? await backgroundStore.remove(friendId: friend.friendId)
                                backgroundData = nil
                            }
                        } label: {
                            Label("恢复默认背景", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.vertical").frame(width: 32, height: 32)
                }
                .accessibilityIdentifier("chat.more")
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .task {
            backgroundData = try? await backgroundStore.load(friendId: friend.friendId)
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto,
                  let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
            try? await backgroundStore.save(data, friendId: friend.friendId)
            backgroundData = data
        }
    }

    private func sampleBubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(mine ? AppTheme.lightGreen.opacity(0.95) : .white.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.black)
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button("添加附件", systemImage: "plus") {}
                .labelStyle(.iconOnly)
            TextField("消息", text: $draft, axis: .vertical)
                .lineLimit(1...4)
            Button("发送", systemImage: draft.isEmpty ? "mic.fill" : "arrow.up") {}
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 34)
                .background(AppTheme.primaryGreen, in: Circle())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }
}
