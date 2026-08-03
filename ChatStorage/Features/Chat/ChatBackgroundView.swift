import SwiftUI

enum ChatBackgroundContentMode: Equatable, Sendable { case fill }

enum ChatBackgroundLayout {
    static let contentMode: ChatBackgroundContentMode = .fill
    static let coversSafeAreas = true
    static let clipsOverflow = true
}

struct ChatBackgroundView: View {
    let imageData: Data?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    PatternBackground()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
