import SwiftUI

enum AppIdentity {
    static let displayName = "Chat Storage"
}

@main
struct ChatStorageApp: App {
    var body: some Scene {
        WindowGroup {
            Text(AppIdentity.displayName)
        }
    }
}
