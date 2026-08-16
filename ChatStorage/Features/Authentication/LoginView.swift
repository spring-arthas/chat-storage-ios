import PhotosUI
import SwiftUI
import UIKit

struct LoginView: View {
    @Bindable var model: LoginViewModel
    @State private var registrationModel: RegistrationViewModel
    @State private var showsRegistration = false
    @State private var registrationMessage: String?
    let serverDescription: String
    let biometricAuthenticator: any BiometricAuthenticating
    let onAuthenticated: (AuthenticatedUser) -> Void
    let onOpenServerSettings: () -> Void

    init(
        model: LoginViewModel,
        authRepository: any AuthRepository,
        serverDescription: String,
        biometricAuthenticator: any BiometricAuthenticating,
        onAuthenticated: @escaping (AuthenticatedUser) -> Void,
        onOpenServerSettings: @escaping () -> Void
    ) {
        self.model = model
        _registrationModel = State(initialValue: RegistrationViewModel(repository: authRepository))
        self.serverDescription = serverDescription
        self.biometricAuthenticator = biometricAuthenticator
        self.onAuthenticated = onAuthenticated
        self.onOpenServerSettings = onOpenServerSettings
    }

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
                        if let registrationMessage {
                            Text(registrationMessage)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.deepGreen)
                                .frame(maxWidth: .infinity, alignment: .leading)
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

                        Button("使用 Face ID", systemImage: "faceid") {
                            Task {
                                await model.loginWithBiometrics(using: biometricAuthenticator)
                                if case .authenticated(let user) = model.state { onAuthenticated(user) }
                            }
                        }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .tint(AppTheme.deepGreen)
                            .disabled(model.state == .loading)

                        Button("创建账号", systemImage: "person.badge.plus") {
                            registrationModel.reset()
                            registrationMessage = nil
                            showsRegistration = true
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .disabled(model.state == .loading)
                    }
                    .padding(22)
                    .glassCard()
                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 22)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showsRegistration) {
            RegisterView(model: registrationModel) { user in
                model.account = user.username
                registrationMessage = "账号创建成功，请输入密码登录"
                showsRegistration = false
            }
        }
    }
}

private struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RegistrationViewModel
    let onRegistered: (AuthenticatedUser) -> Void
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreviewData: Data?
    @State private var avatarError: String?

    var body: some View {
        // [修改] 先在主线程读取状态，再把普通字符串交给 PhotosPicker 的 Sendable 标签闭包。
        let avatarPickerTitle = avatarPreviewData == nil ? "选择头像" : "更换头像"
        NavigationStack {
            Form {
                Section("头像（可选）") {
                    HStack(spacing: 16) {
                        avatarPreview
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label(avatarPickerTitle, systemImage: "photo")
                        }
                    }
                    if let avatarError {
                        Text(avatarError).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("账号信息") {
                    TextField("手机号或邮箱", text: $model.account)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    TextField("邮箱", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                }

                Section("设置密码") {
                    SecureField("密码（至少6位）", text: $model.password)
                        .textContentType(.newPassword)
                    SecureField("确认密码", text: $model.confirmPassword)
                        .textContentType(.newPassword)
                }

                if case .failed(let message) = model.state {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task {
                            await model.register()
                            if case .registered(let user) = model.state { onRegistered(user) }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if model.state == .loading { ProgressView().controlSize(.small) }
                            Text(model.state == .loading ? "正在注册" : "创建账号")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(model.state == .loading)
                    .accessibilityIdentifier("register.submit")
                }
            }
            .navigationTitle("创建账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回登录") { dismiss() }
                }
            }
            .task(id: avatarItem) {
                guard let avatarItem else { return }
                do {
                    guard let source = try await avatarItem.loadTransferable(type: Data.self) else {
                        throw ProfileAvatarImageProcessor.ProcessingError.invalidImage
                    }
                    let jpeg = try await ProfileAvatarImageProcessor.prepareJPEG(from: source)
                    avatarPreviewData = jpeg
                    model.avatarData = jpeg.base64EncodedString()
                    avatarError = nil
                } catch {
                    avatarPreviewData = nil
                    model.avatarData = nil
                    avatarError = (error as? LocalizedError)?.errorDescription ?? "头像处理失败"
                }
            }
        }
    }

    private var avatarPreview: some View {
        Group {
            if let avatarPreviewData, let image = UIImage(data: avatarPreviewData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(AppTheme.primaryGreen.gradient)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(Circle())
    }
}
