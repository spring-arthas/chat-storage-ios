import CryptoKit
import Foundation
import Network
import Security

enum TransportSecurity {
    static let mediaScheme = "https"
    private static let certificateName = "chat-storage-local-ca"
    private static let verificationQueue = DispatchQueue(label: "com.alibaba.chatstorage.tls-verification")
    private static let rootCertificateData: Data? = {
        guard let url = Bundle.main.url(forResource: certificateName, withExtension: "der") else { return nil }
        return try? Data(contentsOf: url)
    }()

    // [修改] 所有自定义帧连接强制 TLS 1.2 以上，只信任 App 内置 CA 并校验当前服务器主机名。
    static func makeParameters(expectedHost: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let normalizedHost = normalize(host: expectedHost)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, protocolTrust, complete in
                let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                complete(evaluateServerTrust(trust, expectedHost: normalizedHost))
            },
            verificationQueue
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    // [修改] 媒体 HTTPS 和 Socket TLS 共用同一 CA、同一主机名校验规则。
    static func evaluateServerTrust(_ trust: SecTrust, expectedHost: String) -> Bool {
        guard let rootCertificateData,
              let rootCertificate = SecCertificateCreateWithData(nil, rootCertificateData as CFData) else {
            return false
        }
        let policy = SecPolicyCreateSSL(true, normalize(host: expectedHost) as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    private static func normalize(host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

enum ServerConfigurationError: Error, Equatable, Sendable {
    case emptyHost
    case invalidPort(name: String, value: Int)
}

struct ServerConfiguration: Codable, Equatable, Sendable {
    static let defaultHost = "172.21.32.64"
    static let defaultControlPort = 10_086
    static let defaultUploadPort = 10_087
    static let defaultDownloadPort = 10_088
    static let defaultMediaPort = 10_188

    let host: String
    let controlPort: Int
    let uploadPort: Int
    let downloadPort: Int
    let mediaPort: Int

    init(
        host: String = Self.defaultHost,
        controlPort: Int = Self.defaultControlPort,
        uploadPort: Int = Self.defaultUploadPort,
        downloadPort: Int = Self.defaultDownloadPort,
        mediaPort: Int = Self.defaultMediaPort
    ) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw ServerConfigurationError.emptyHost }
        try Self.validate(port: controlPort, name: "control")
        try Self.validate(port: uploadPort, name: "upload")
        try Self.validate(port: downloadPort, name: "download")
        try Self.validate(port: mediaPort, name: "media")
        self.host = trimmedHost
        self.controlPort = controlPort
        self.uploadPort = uploadPort
        self.downloadPort = downloadPort
        self.mediaPort = mediaPort
    }

    static var `default`: ServerConfiguration {
        try! ServerConfiguration()
    }

    // [修改] 本地持久化按完整服务器端点分区，避免不同服务器复用相同 userId 时串数据。
    var storageScopeID: String {
        let canonical = [
            host.lowercased(),
            String(controlPort),
            String(uploadPort),
            String(downloadPort),
            String(mediaPort),
        ].joined(separator: ":")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(port: Int, name: String) throws {
        guard (1...65_535).contains(port) else {
            throw ServerConfigurationError.invalidPort(name: name, value: port)
        }
    }
}

protocol ServerConfigurationStore: Sendable {
    func load() throws -> ServerConfiguration?
    func save(_ configuration: ServerConfiguration) throws
}

enum ServerConfigurationStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
}

final class UserDefaultsServerConfigurationStore: ServerConfigurationStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "chat-storage.server-configuration") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> ServerConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try ProtocolJSON.decoder().decode(ServerConfiguration.self, from: data)
        } catch {
            throw ServerConfigurationStoreError.decodingFailed
        }
    }

    func save(_ configuration: ServerConfiguration) throws {
        do {
            defaults.set(try ProtocolJSON.encoder().encode(configuration), forKey: key)
        } catch {
            throw ServerConfigurationStoreError.encodingFailed
        }
    }
}
