import SwiftUI

struct FriendAvatarView: View {
    let friend: ChatFriend
    let size: CGFloat

    var body: some View {
        Group {
            if let data = friend.avatar.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(AppTheme.primaryGreen.gradient)
                    Text(String(friend.displayName.prefix(1)))
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if friend.isOnline {
                Circle().fill(.green).frame(width: size * 0.22, height: size * 0.22).overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .accessibilityLabel("\(friend.displayName)的头像")
    }
}
