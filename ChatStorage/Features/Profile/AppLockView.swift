import SwiftUI

struct AppLockView: View {
    let controller: AppLockController
    let onUnlocked: () async -> Void

    var body: some View {
        ZStack {
            PatternBackground()
            VStack(spacing: 22) {
                Image(systemName: "faceid")
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(.white)
                Text("Chat Storage 已锁定")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Button("使用 Face ID 解锁") {
                    Task {
                        await controller.unlock()
                        if !controller.isLocked { await onUnlocked() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryGreen)
                .disabled(controller.isChanging)
            }
            .padding(28)
            .glassCard()
            .padding(.horizontal, 28)
        }
        .alert("解锁失败", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.clearError() } }
        )) {
            Button("重试") { Task { await controller.unlock() } }
        } message: {
            Text(controller.errorMessage ?? "请稍后重试")
        }
    }
}
