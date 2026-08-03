import SwiftUI

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var controlPort: String
    @State private var uploadPort: String
    @State private var downloadPort: String
    @State private var mediaPort: String
    @State private var message: String?
    let onSave: (ServerConfiguration) throws -> Void

    init(configuration: ServerConfiguration, onSave: @escaping (ServerConfiguration) throws -> Void) {
        _host = State(initialValue: configuration.host)
        _controlPort = State(initialValue: String(configuration.controlPort))
        _uploadPort = State(initialValue: String(configuration.uploadPort))
        _downloadPort = State(initialValue: String(configuration.downloadPort))
        _mediaPort = State(initialValue: String(configuration.mediaPort))
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
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("服务器设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let configuration = try ServerConfiguration(
                                host: host,
                                controlPort: Int(controlPort) ?? 0,
                                uploadPort: Int(uploadPort) ?? 0,
                                downloadPort: Int(downloadPort) ?? 0,
                                mediaPort: Int(mediaPort) ?? 0
                            )
                            try onSave(configuration)
                            dismiss()
                        } catch {
                            message = "请检查服务器地址和端口。"
                        }
                    }
                }
            }
        }
    }

    private func portField(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.numberPad)
    }
}
