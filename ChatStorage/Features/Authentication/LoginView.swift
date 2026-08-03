import SwiftUI

struct LoginView: View {
    @Bindable var model: LoginViewModel
    let serverDescription: String
    let onAuthenticated: (AuthenticatedUser) -> Void
    let onOpenServerSettings: () -> Void

    var body: some View {
        ZStack {
            PatternBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Spacer(minLength: 52)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 35, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(.white.opacity(0.15), in: Circle())
                    Text("你的消息与文件，只属于你")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("连接自己的服务器，随时查看聊天记录与私人网盘。")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.82))

                    VStack(spacing: 18) {
                        TextField("账号", text: $model.account)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .padding(16)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                        SecureField("密码", text: $model.password)
                            .textContentType(.password)
                            .padding(16)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))

                        Button(action: onOpenServerSettings) {
                            HStack {
                                Circle().fill(.green).frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("服务器状态").font(.caption).foregroundStyle(.secondary)
                                    Text(serverDescription).font(.subheadline).foregroundStyle(.primary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .buttonStyle(.plain)

                        if case .failed(let message) = model.state {
                            Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task {
                                await model.login()
                                if case .authenticated(let user) = model.state { onAuthenticated(user) }
                            }
                        } label: {
                            HStack {
                                if model.state == .loading { ProgressView().tint(.white) }
                                Text("登录").fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primaryGreen)
                        .disabled(model.state == .loading)

                        Button("使用 Face ID", systemImage: "faceid") {}
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .tint(AppTheme.deepGreen)
                    }
                    .padding(22)
                    .glassCard()
                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 22)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
