import Foundation

enum ServerConfigurationError: Error, Equatable, Sendable {
    case emptyHost
    case invalidPort(name: String, value: Int)
}

struct ServerConfiguration: Codable, Equatable, Sendable {
    static let defaultHost = "172.21.33.156"
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
