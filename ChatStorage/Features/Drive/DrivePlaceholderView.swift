import SwiftUI

struct DrivePlaceholderView: View {
    let sampleMode: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        storageCard("文档", icon: "doc.fill", color: AppTheme.documentBlue)
                        storageCard("媒体", icon: "play.rectangle.fill", color: AppTheme.mediaCoral)
                        storageCard("归档", icon: "archivebox.fill", color: AppTheme.archiveViolet)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if sampleMode {
                    Section("最近文件") {
                        Label("产品设计稿.pdf", systemImage: "doc.richtext.fill")
                        Label("周末视频.mov", systemImage: "video.fill")
                    }
                } else {
                    ContentUnavailableView("网盘为空", systemImage: "externaldrive", description: Text("连接服务器后即可浏览私人文件。"))
                }
            }
            .navigationTitle("网盘")
        }
    }

    private func storageCard(_ title: String, icon: String, color: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white)
            Text(title).font(.caption.bold()).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18).background(color.gradient, in: RoundedRectangle(cornerRadius: 18))
    }
}
