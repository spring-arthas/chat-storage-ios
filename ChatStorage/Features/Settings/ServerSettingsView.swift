import SwiftUI

struct ServerSettingsDraft: Equatable, Sendable {
    let host: String
    let controlPort: String
    let uploadPort: String
    let downloadPort: String
    let mediaPort: String

    func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(
            host: host,
            controlPort: Int(controlPort) ?? 0,
            uploadPort: Int(uploadPort) ?? 0,
            downloadPort: Int(downloadPort) ?? 0,
            mediaPort: Int(mediaPort) ?? 0
        )
    }
}

struct ControlServerConnectionTester: Sendable {
    private let connectionFactory: @Sendable (ServerConfiguration) -> any ControlConnection

    init(
        connectionFactory: @escaping @Sendable (ServerConfiguration) -> any ControlConnection = {
            NWControlConnection(configuration: $0)
        }
    ) {
        self.connectionFactory = connectionFactory
    }

    func test(configuration: ServerConfiguration) async throws {
        let connection = connectionFactory(configuration)
        // 测试连接始终是独立的普通 TCP Socket，成功或失败都立即关闭，不影响登录连接。
        do {
            try await connection.connect()
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            throw error
        }
    }
}

enum ServerConnectionTestVisibleState: Equatable {
    case idle
    case testing
    case succeeded
    case failed(String)
}

enum ServerConnectionTestState: Equatable {
    case idle
    case testing(testedDraft: ServerSettingsDraft)
    case succeeded(testedDraft: ServerSettingsDraft)
    case failed(String, testedDraft: ServerSettingsDraft)

    // [修改] 测试结果只属于当次输入，字段变化后不能继续显示旧成功或旧失败。
    func visibleState(for draft: ServerSettingsDraft) -> ServerConnectionTestVisibleState {
        switch self {
        case .idle:
            return .idle
        case .testing(let testedDraft):
            return testedDraft == draft ? .testing : .idle
        case .succeeded(let testedDraft):
            return testedDraft == draft ? .succeeded : .idle
        case .failed(let detail, let testedDraft):
            return testedDraft == draft ? .failed(detail) : .idle
        }
    }
}

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var controlPort: String
    @State private var uploadPort: String
    @State private var downloadPort: String
    @State private var mediaPort: String
    @State private var message: String?
    @State private var isSaving = false
    @State private var connectionTestState: ServerConnectionTestState = .idle
    private let connectionTester: ControlServerConnectionTester
    let onSave: (ServerConfiguration) async throws -> Void

    init(
        configuration: ServerConfiguration,
        connectionTester: ControlServerConnectionTester = ControlServerConnectionTester(),
        onSave: @escaping (ServerConfiguration) async throws -> Void
    ) {
        _host = State(initialValue: configuration.host)
        _controlPort = State(initialValue: String(configuration.controlPort))
        _uploadPort = State(initialValue: String(configuration.uploadPort))
        _downloadPort = State(initialValue: String(configuration.downloadPort))
        _mediaPort = State(initialValue: String(configuration.mediaPort))
        self.connectionTester = connectionTester
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("私人服务器") {
                    TextField("主机地址", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    portField("控制端口", value: $controlPort)
                    portField("上传端口", value: $uploadPort)
                    portField("下载端口", value: $downloadPort)
                    portField("媒体端口", value: $mediaPort)
                }
                Section {
                    Label("首次连接局域网服务器时，请允许本地网络访问。", systemImage: "network")
                }
                Section("连接检测") {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试控制连接")
                            Spacer()
                            if visibleConnectionTestState == .testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(visibleConnectionTestState == .testing || isSaving)
                    .accessibilityIdentifier("server.test-connection")
                    switch visibleConnectionTestState {
                    case .idle, .testing:
                        EmptyView()
                    case .succeeded:
                        Label("控制端口 TCP 连接成功", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let detail):
                        Label(detail, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("服务器设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do {
                                let configuration = try draft.configuration()
                                try await onSave(configuration)
                                dismiss()
                            } catch {
                                message = "请检查服务器地址和端口。"
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func portField(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.numberPad)
    }

    private var draft: ServerSettingsDraft {
        ServerSettingsDraft(
            host: host,
            controlPort: controlPort,
            uploadPort: uploadPort,
            downloadPort: downloadPort,
            mediaPort: mediaPort
        )
    }

    private var visibleConnectionTestState: ServerConnectionTestVisibleState {
        connectionTestState.visibleState(for: draft)
    }

    @MainActor
    private func testConnection() async {
        let testedDraft = draft
        connectionTestState = .testing(testedDraft: testedDraft)
        message = nil
        do {
            try await connectionTester.test(configuration: testedDraft.configuration())
            // [修改] 用户在检测期间改了字段时，旧请求完成也不能覆盖新输入的状态。
            guard draft == testedDraft else {
                if connectionTestState == .testing(testedDraft: testedDraft) {
                    connectionTestState = .idle
                }
                return
            }
            connectionTestState = .succeeded(testedDraft: testedDraft)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            guard draft == testedDraft else {
                if connectionTestState == .testing(testedDraft: testedDraft) {
                    connectionTestState = .idle
                }
                return
            }
            connectionTestState = .failed(
                detail.isEmpty ? "控制连接失败" : detail,
                testedDraft: testedDraft
            )
        }
    }
}
