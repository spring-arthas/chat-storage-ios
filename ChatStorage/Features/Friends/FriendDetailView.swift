import SwiftUI

struct FriendDetailView: View {
    let friend: ChatFriend

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    FriendAvatarView(friend: friend, size: 92)
                    Text(friend.displayName).font(.title2.bold())
                    Text("@\(friend.username)").foregroundStyle(.secondary)
                    Label(friend.isOnline ? "在线" : "离线", systemImage: friend.isOnline ? "circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(friend.isOnline ? .green : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            Section("好友信息") {
                LabeledContent("昵称", value: friend.nickname ?? "未设置")
                LabeledContent("备注", value: friend.alias ?? "未设置")
                LabeledContent("好友 ID", value: String(friend.friendId))
            }
        }
        .navigationTitle("好友资料")
        .navigationBarTitleDisplayMode(.inline)
    }
}
