import SwiftUI

struct FriendDetailView: View {
    @State private var model: FriendDetailViewModel
    private let onAliasUpdated: () async -> Void

    init(friend: ChatFriend, repository: any ChatRepository, onAliasUpdated: @escaping () async -> Void) {
        _model = State(initialValue: FriendDetailViewModel(friend: friend, repository: repository))
        self.onAliasUpdated = onAliasUpdated
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    FriendAvatarView(friend: model.friend, size: 92)
                    Text(model.displayName).font(.title2.bold())
                    Text("@\(model.friend.username)").foregroundStyle(.secondary)
                    Label(model.friend.isOnline ? "在线" : "离线", systemImage: model.friend.isOnline ? "circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(model.friend.isOnline ? .green : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            Section("好友信息") {
                LabeledContent("昵称", value: model.friend.nickname ?? "未设置")
                LabeledContent("好友 ID", value: String(model.friend.friendId))
            }
            Section("好友备注") {
                TextField("输入备注", text: $model.alias)
                    .textInputAutocapitalization(.never)
                Button {
                    Task {
                        if await model.saveAlias() { await onAliasUpdated() }
                    }
                } label: {
                    if model.isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("保存备注").frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.isSaving)
            }
        }
        .navigationTitle("好友资料")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("知道了") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "请稍后重试")
        }
    }
}
