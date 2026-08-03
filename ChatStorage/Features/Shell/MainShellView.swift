import SwiftUI

struct MainShellView: View {
    let user: AuthenticatedUser
    let friendRepository: any FriendRepository
    let sampleMode: Bool

    var body: some View {
        TabView {
            Tab("消息", systemImage: "bubble.left.and.bubble.right.fill") {
                MessagesPlaceholderView(repository: friendRepository, sampleMode: sampleMode)
            }
            Tab("网盘", systemImage: "externaldrive.fill") {
                DrivePlaceholderView(sampleMode: sampleMode)
            }
            Tab("我的", systemImage: "person.crop.circle.fill") {
                ProfilePlaceholderView(user: user)
            }
        }
        .tint(AppTheme.primaryGreen)
    }
}
