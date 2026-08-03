import SwiftUI

struct MessagesPlaceholderView: View {
    let sampleMode: Bool

    var body: some View {
        NavigationStack {
            List {
                if sampleMode {
                    Section("置顶") {
                        conversation("小林", message: "晚点把照片传到网盘", icon: "person.crop.circle.fill", unread: 2)
                    }
                    Section("最近消息") {
                        conversation("设计讨论", message: "新的聊天背景很舒服", icon: "person.2.circle.fill", unread: 0)
                        conversation("阿哲", message: "收到，明天见", icon: "person.crop.circle", unread: 0)
                    }
                } else {
                    ContentUnavailableView("暂无消息", systemImage: "bubble.left.and.bubble.right", description: Text("好友和会话会在同步后显示在这里。"))
                }
            }
            .navigationTitle("消息")
        }
    }

    private func conversation(_ name: String, message: String, icon: String, unread: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(AppTheme.primaryGreen)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(.white).padding(7).background(AppTheme.primaryGreen, in: Circle()) }
        }
        .padding(.vertical, 5)
    }
}
