import SwiftUI

struct PatternBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.deepGreen, AppTheme.primaryGreen, Color(red: 0.63, green: 0.75, blue: 0.21)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [AppTheme.lightGreen.opacity(0.7), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 360
            )
            Canvas { context, size in
                let spacing: CGFloat = 64
                var path = Path()
                for y in stride(from: -spacing, through: size.height + spacing, by: spacing) {
                    for x in stride(from: -spacing, through: size.width + spacing, by: spacing) {
                        path.addArc(center: CGPoint(x: x + 18, y: y + 18), radius: 10, startAngle: .degrees(15), endAngle: .degrees(270), clockwise: false)
                        path.move(to: CGPoint(x: x + 35, y: y + 12))
                        path.addCurve(to: CGPoint(x: x + 52, y: y + 30), control1: CGPoint(x: x + 48, y: y + 6), control2: CGPoint(x: x + 55, y: y + 18))
                        path.move(to: CGPoint(x: x + 8, y: y + 46))
                        path.addLine(to: CGPoint(x: x + 25, y: y + 37))
                        path.addLine(to: CGPoint(x: x + 31, y: y + 52))
                    }
                }
                context.stroke(path, with: .color(.white.opacity(contrast == .increased ? 0.18 : 0.09)), lineWidth: 1.25)
            }
            .opacity(reduceTransparency ? 0.45 : 1)
        }
        .ignoresSafeArea()
    }
}
