import SwiftUI

struct FriendManagementView: View {
    enum Mode: String, CaseIterable { case search = "查找好友"; case requests = "好友申请" }

    @Environment(\.dismiss) private var dismiss
    @State private var model: FriendManagementViewModel
    @State private var mode: Mode = .search
    @State private var keyword = ""
    @State private var requestMessage = "你好，我想加你为好友"

    init(repository: any ChatRepository) { _model = State(initialValue: FriendManagementViewModel(repository: repository)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("好友管理", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding()
                if mode == .search { searchContent } else { requestsContent }
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await model.loadRequests() }
            .onChange(of: mode) { _, value in if value == .requests { Task { await model.loadRequests() } } }
            .alert("好友操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
                Button("知道了") { model.clearError() }
            } message: { Text(model.errorMessage ?? "请稍后重试") }
        }
    }

    private var searchContent: some View {
        List {
            Section {
                HStack {
                    TextField("用户名或昵称", text: $keyword).textInputAutocapitalization(.never)
                    Button("搜索", systemImage: "magnifyingglass") { Task { await model.search(keyword: keyword) } }.labelStyle(.iconOnly)
                }
                TextField("申请说明", text: $requestMessage)
            }
            Section {
                ForEach(model.results) { result in
                    HStack(spacing: 12) {
                        Circle().fill(AppTheme.lightGreen).frame(width: 42, height: 42).overlay(Text(String(result.displayName.prefix(1))).bold())
                        VStack(alignment: .leading) { Text(result.displayName); Text("@\(result.username)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if result.canSendFriendRequest {
                            // [修改] 服务端会明确返回“添加/重新申请”，可操作状态必须显示按钮而不是只读文字。
                            Button(result.friendActionTitle) { Task { await model.add(result, message: requestMessage) } }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.primaryGreen)
                        } else if let status = result.friendStatusDescription {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay { if model.isLoading && model.results.isEmpty { ProgressView() } }
    }

    private var requestsContent: some View {
        List {
            if model.pendingRequests.isEmpty { ContentUnavailableView("暂无好友申请", systemImage: "person.badge.clock") }
            ForEach(model.pendingRequests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.displayName).font(.headline)
                    if !request.requestMessage.isEmpty { Text(request.requestMessage).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        Button("拒绝", role: .destructive) { Task { await model.handle(request, accept: false) } }.buttonStyle(.bordered)
                        Button("同意") { Task { await model.handle(request, accept: true) } }.buttonStyle(.borderedProminent).tint(AppTheme.primaryGreen)
                    }
                }.padding(.vertical, 4)
            }
        }.refreshable { await model.loadRequests() }
    }
}
