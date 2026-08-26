import QuickLook
import SwiftUI

struct TransferCenterView: View {
    @State private var model: TransferCenterViewModel
    @State private var quickLookAccess: TransferScopedURLAccess?
    @State private var shareAccess: TransferScopedURLAccess?

    init(store: FileTransferTaskStore, manager: (any TransferManaging)?, userId: Int64, serverScopeID: String) {
        _model = State(initialValue: TransferCenterViewModel(
            store: store,
            manager: manager,
            userId: userId,
            serverScopeID: serverScopeID
        ))
    }

    var body: some View {
        List {
            if model.filteredTasks.isEmpty {
                ContentUnavailableView("暂无传输任务", systemImage: "arrow.up.arrow.down.circle")
                    .listRowBackground(Color.clear)
            } else {
                let active = model.filteredTasks.filter { $0.status.isExecuting }
                let paused = model.filteredTasks.filter { $0.status == .paused || $0.status == .pausedAuthentication }
                let finished = model.filteredTasks.filter(\.status.isTerminal)
                if !active.isEmpty { Section("进行中") { rows(active) } }
                if !paused.isEmpty { Section("已暂停") { rows(paused) } }
                if !finished.isEmpty { Section("已完成与失败") { rows(finished) } }
            }
        }
        .navigationTitle("传输中心")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu("筛选", systemImage: "line.3.horizontal.decrease.circle") {
                    Picker("方向", selection: $model.directionFilter) {
                        Text("全部方向").tag(TransferDirectionFilter.all)
                        Text("上传").tag(TransferDirectionFilter.upload)
                        Text("下载").tag(TransferDirectionFilter.download)
                    }
                    Picker("状态", selection: $model.statusFilter) {
                        Text("全部状态").tag(TransferStatusFilter.all)
                        Text("进行中").tag(TransferStatusFilter.active)
                        Text("已暂停").tag(TransferStatusFilter.paused)
                        Text("已完成").tag(TransferStatusFilter.completed)
                        Text("失败").tag(TransferStatusFilter.failed)
                        Text("已取消").tag(TransferStatusFilter.cancelled)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("传输操作", systemImage: "ellipsis.circle") {
                    Button("全部取消", role: .destructive) { Task { await model.cancelAll() } }
                        .disabled(model.cancellableCount == 0)
                    Button("清理已完成与失败") { Task { await model.clearFinished() } }
                        .disabled(!model.tasks.contains { $0.status == .completed || $0.status == .failed })
                }
            }
        }
        .task { await model.load() }
        .task { await model.observe() }
        .alert("传输操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("知道了") { model.clearError() }
        } message: { Text(model.errorMessage ?? "请稍后重试") }
        .sheet(item: $quickLookAccess) { access in
            TransferQuickLookView(url: access.url)
        }
        .sheet(item: $shareAccess) { access in
            TransferShareSheet(url: access.url)
        }
    }

    @ViewBuilder
    private func rows(_ tasks: [TransferTaskRecord]) -> some View {
        ForEach(tasks) { task in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: task.direction == .upload ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(task.direction == .upload ? AppTheme.documentBlue : AppTheme.primaryGreen)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.fileName).lineLimit(1)
                        Text("\(statusText(task.status)) · \(ByteCountFormatter.string(fromByteCount: task.transferredBytes, countStyle: .file)) / \(task.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: task.fileSize, countStyle: .file) : "未知大小")")
                            .font(.caption).foregroundStyle(task.status == .failed ? .red : .secondary)
                    }
                    Spacer()
                    actionButtons(task)
                }
                if task.fileSize > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: task.progress)
                            .tint(task.status == .failed ? .red : AppTheme.primaryGreen)
                        if task.status == .running || task.status == .verifying {
                            // [修改] 上传中显示实时百分比，进度条增长效果更直观。
                            Text("\(Int((task.progress * 100).rounded()))%")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                } else if task.status.isExecuting {
                    ProgressView().tint(AppTheme.primaryGreen)
                }
                if let error = task.errorMessage, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if task.status == .running, let speed = task.bytesPerSecond, speed > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/秒")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func actionButtons(_ task: TransferTaskRecord) -> some View {
        HStack(spacing: 8) {
            switch task.status {
            case .preparing:
                Button("取消", role: .destructive) { Task { await model.cancel(task) } }
            case .failed:
                Button("重试") { Task { await model.retry(task) } }
            case .paused, .pausedAuthentication:
                Button("继续") { Task { await model.retry(task) } }
            case .queued, .hashing, .running, .verifying:
                Button("暂停") { Task { await model.pause(task) } }
            case .completed:
                if task.direction == .download {
                    Button("打开") { quickLookAccess = model.fileAccess(for: task) }
                    Button("分享") { shareAccess = model.fileAccess(for: task) }
                }
            case .cancelled:
                EmptyView()
            }
            // [修改] 永久失败任务可主动放弃，避免无法清理的记录一直滞留。
            if model.canCancel(task) {
                Button(task.status == .failed ? "放弃" : "取消", role: .destructive) {
                    Task { await model.cancel(task) }
                }
            }
        }
        // [修改] List 行内按钮只响应按钮自身，点击文件名、进度条等任务内容不得触发暂停/取消。
        .buttonStyle(.borderless)
    }

    private func statusText(_ status: TransferStatus) -> String {
        switch status {
        case .preparing: "正在导入"
        case .queued: "等待中"
        case .hashing: "首次校验"
        case .running: "传输中"
        case .verifying: "服务端正在校验"
        case .paused: "已暂停"
        case .pausedAuthentication: "等待登录"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

private struct TransferQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct TransferShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
