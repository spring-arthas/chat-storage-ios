import SwiftUI

struct ProfilePlaceholderView: View {
    let user: AuthenticatedUser

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 58)).foregroundStyle(AppTheme.primaryGreen)
                        VStack(alignment: .leading) {
                            Text(user.nickname ?? user.username).font(.title3.bold())
                            Text("@\(user.username)").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section("设置") {
                    Label("服务器", systemImage: "network")
                    Label("通知", systemImage: "bell.fill")
                    Label("存储空间", systemImage: "internaldrive.fill")
                    Label("外观", systemImage: "paintpalette.fill")
                    Label("隐私与安全", systemImage: "lock.shield.fill")
                }
            }
            .navigationTitle("我的")
        }
    }
}
