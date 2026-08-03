import SwiftUI

enum AppTheme {
    static let primaryGreen = Color(red: 0.12, green: 0.48, blue: 0.35)
    static let deepGreen = Color(red: 0.04, green: 0.24, blue: 0.19)
    static let lightGreen = Color(red: 0.72, green: 0.91, blue: 0.56)
    static let sheet = Color.white.opacity(0.94)
    static let documentBlue = Color(red: 0.24, green: 0.53, blue: 0.93)
    static let mediaCoral = Color(red: 0.95, green: 0.42, blue: 0.35)
    static let archiveViolet = Color(red: 0.48, green: 0.38, blue: 0.75)
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: AppTheme.deepGreen.opacity(0.18), radius: 28, y: 16)
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
