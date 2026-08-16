import SwiftUI
import UIKit

// [修改] 消息页右上角"待接受好友申请"入口的列表视图，处理完同步刷新消息页。
struct FriendRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: FriendManagementViewModel
    private let onChanged: () async -> Void

    init(repository: any ChatRepository, onChanged: @escaping () async -> Void) {
        _model = State(initialValue: FriendManagementViewModel(repository: repository))
        self.onChanged = onChanged
    }

    var body: some View {
        NavigationStack {
            List {
                if model.pendingRequests.isEmpty {
                    ContentUnavailableView("暂无待接受的好友申请", systemImage: "person.badge.clock")
                        .listRowBackground(Color.clear)
                }
                ForEach(model.pendingRequests) { request in
                    HStack(spacing: 12) {
                        avatar(request)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.displayName).font(.headline)
                            if !request.requestMessage.isEmpty {
                                Text(request.requestMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button {
                            Task { await handle(request, accept: false) }
                        } label: {
                            Image(systemName: "xmark").font(.body.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityIdentifier("friend.request.\(request.id).reject")
                        Button {
                            Task { await handle(request, accept: true) }
                        } label: {
                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primaryGreen)
                        .accessibilityIdentifier("friend.request.\(request.id).accept")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("待接受好友申请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await model.loadRequests() }
            .refreshable { await model.loadRequests() }
            .alert("好友操作失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )) {
                Button("知道了") { model.clearError() }
            } message: { Text(model.errorMessage ?? "请稍后重试") }
        }
    }

    private func handle(_ request: FriendRequestItem, accept: Bool) async {
        await model.handle(request, accept: accept)
        await onChanged()
    }

    private func avatar(_ request: FriendRequestItem) -> some View {
        Group {
            if let data = request.senderAvatar.flatMap({ Data(base64Encoded: $0) }),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(AppTheme.lightGreen)
                    Text(String(request.displayName.prefix(1))).font(.headline).foregroundStyle(.primary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }
}
