import CryptoKit
import XCTest
import Network
import Security
@testable import ChatStorage

final class ServerConfigurationTests: XCTestCase {
    func testConfigurationRejectsEmptyHost() {
        XCTAssertThrowsError(try ServerConfiguration(host: "", controlPort: 10_086))
        XCTAssertThrowsError(try ServerConfiguration(host: "   ", controlPort: 10_086))
    }

    func testConfigurationProvidesServicePorts() throws {
        let configuration = try ServerConfiguration(host: "192.168.1.8", controlPort: 10_086)

        XCTAssertEqual(configuration.host, "192.168.1.8")
        XCTAssertEqual(configuration.uploadPort, 10_087)
        XCTAssertEqual(configuration.downloadPort, 10_088)
        XCTAssertEqual(configuration.mediaPort, 10_188)
    }

    func testConfigurationRejectsInvalidPorts() {
        XCTAssertThrowsError(try ServerConfiguration(host: "server.lan", controlPort: 0))
        XCTAssertThrowsError(try ServerConfiguration(host: "server.lan", controlPort: 10_086, uploadPort: 65_536))
        XCTAssertThrowsError(try ServerConfiguration(host: "server.lan", controlPort: 10_086, mediaPort: -1))
    }

    func testStorePersistsConfiguration() throws {
        let suiteName = "ServerConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsServerConfigurationStore(defaults: defaults)
        let expected = try ServerConfiguration(
            host: " chat.example.lan ",
            controlPort: 20_086,
            uploadPort: 20_087,
            downloadPort: 20_088,
            mediaPort: 20_188
        )

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(try store.load()?.host, "chat.example.lan")
    }

    // [修改] 本地任务、缓存和预览必须按完整服务器端点隔离。
    func testStorageScopeIDIsStableAndChangesWithServerEndpoint() throws {
        let first = try ServerConfiguration(host: " Chat.Example.Lan ", controlPort: 10_086)
        let same = try ServerConfiguration(host: "chat.example.lan", controlPort: 10_086)
        let otherPort = try ServerConfiguration(host: "chat.example.lan", controlPort: 20_086)

        XCTAssertEqual(first.storageScopeID, same.storageScopeID)
        XCTAssertNotEqual(first.storageScopeID, otherPort.storageScopeID)
    }

    func testCustomFrameTransportParametersUsePlainTCP() {
        let parameters = TransportSecurity.makePlainTCPParameters()

        XCTAssertTrue(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
        XCTAssertFalse(
            parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options }
        )
    }

    // 自定义帧端口改为普通 TCP 后，媒体资源仍必须通过 HTTPS 获取。
    func testMediaTransportRemainsHTTPS() {
        XCTAssertEqual(TransportSecurity.mediaScheme, "https")
    }

    // [修改] App 必须携带与 net-server 内嵌 TLS 证书配套的严格 CA，不能依赖设备手工安装证书。
    func testApplicationBundlesExpectedStrictLocalCA() throws {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "chat-storage-local-ca",
            withExtension: "der"
        ))
        let data = try Data(contentsOf: url)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(fingerprint, "A63D920FF3FCE18C581C694B9DB2517222148893B0FA2413C525570897E4F1A7")

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        XCTAssertEqual(
            SecCertificateCopyNormalizedSubjectSequence(certificate),
            SecCertificateCopyNormalizedIssuerSequence(certificate)
        )
    }

    func testServerSettingsDraftBuildsCandidateConfigurationFromCurrentFields() throws {
        let draft = ServerSettingsDraft(
            host: " server.lan ",
            controlPort: "20086",
            uploadPort: "20087",
            downloadPort: "20088",
            mediaPort: "20188"
        )

        let configuration = try draft.configuration()

        XCTAssertEqual(configuration.host, "server.lan")
        XCTAssertEqual(configuration.controlPort, 20_086)
        XCTAssertEqual(configuration.uploadPort, 20_087)
        XCTAssertEqual(configuration.downloadPort, 20_088)
        XCTAssertEqual(configuration.mediaPort, 20_188)
    }

    func testServerSettingsDraftRejectsNonNumericCandidatePort() {
        let draft = ServerSettingsDraft(
            host: "server.lan",
            controlPort: "TLS",
            uploadPort: "10087",
            downloadPort: "10088",
            mediaPort: "10188"
        )

        XCTAssertThrowsError(try draft.configuration())
    }

    // 连接测试页必须展示可读的底层 Socket 错误，不能退化为 NSError 域名。
    func testConnectionErrorProvidesStableLocalizedDescriptions() {
        XCTAssertEqual(ConnectionError.invalidPort(70_000).errorDescription, "端口无效：70000")
        XCTAssertEqual(ConnectionError.failed("证书不受信任").errorDescription, "证书不受信任")
        XCTAssertEqual(ConnectionError.disconnected.errorDescription, "连接已断开")
        XCTAssertEqual(ConnectionError.notConnected.errorDescription, "尚未连接服务器")
        XCTAssertEqual(ConnectionError.connectionTimeout.errorDescription, "连接服务器超时")
    }

    // [修改] 任一服务器字段变化后，旧的连接成功状态必须失效。
    func testServerConnectionTestResultResetsWhenDraftChanges() {
        let original = ServerSettingsDraft(
            host: "server.lan",
            controlPort: "10086",
            uploadPort: "10087",
            downloadPort: "10088",
            mediaPort: "10188"
        )
        let changed = ServerSettingsDraft(
            host: "192.168.1.8",
            controlPort: "10086",
            uploadPort: "10087",
            downloadPort: "10088",
            mediaPort: "10188"
        )
        let state = ServerConnectionTestState.succeeded(testedDraft: original)

        XCTAssertEqual(state.visibleState(for: original), .succeeded)
        XCTAssertEqual(state.visibleState(for: changed), .idle)
    }

    func testControlServerConnectionTesterDisconnectsIndependentConnectionAfterSuccess() async throws {
        let connection = ServerTestControlConnection(result: .success(()))
        let factory = ServerTestConnectionFactory(connection: connection)
        let tester = ControlServerConnectionTester(connectionFactory: factory.make)
        let configuration = try ServerConfiguration(host: "server.lan", controlPort: 20_086)

        try await tester.test(configuration: configuration)

        XCTAssertEqual(factory.configurations, [configuration])
        let counts = await connection.counts()
        XCTAssertEqual(counts.connect, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testControlServerConnectionTesterDisconnectsIndependentConnectionAfterFailure() async throws {
        let connection = ServerTestControlConnection(result: .failure(ConnectionError.failed("连接被拒绝")))
        let factory = ServerTestConnectionFactory(connection: connection)
        let tester = ControlServerConnectionTester(connectionFactory: factory.make)
        let configuration = try ServerConfiguration(host: "server.lan", controlPort: 20_086)

        do {
            try await tester.test(configuration: configuration)
            XCTFail("Expected TCP connection failure")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .failed("连接被拒绝"))
        }

        let counts = await connection.counts()
        XCTAssertEqual(counts.connect, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }
}

private final class ServerTestConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: ServerTestControlConnection
    private var recordedConfigurations: [ServerConfiguration] = []

    init(connection: ServerTestControlConnection) {
        self.connection = connection
    }

    var configurations: [ServerConfiguration] {
        lock.withLock { recordedConfigurations }
    }

    func make(configuration: ServerConfiguration) -> any ControlConnection {
        lock.withLock { recordedConfigurations.append(configuration) }
        return connection
    }
}

private actor ServerTestControlConnection: ControlConnection {
    nonisolated let frames: AsyncThrowingStream<Frame, Error> = AsyncThrowingStream { $0.finish() }
    private let result: Result<Void, Error>
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(result: Result<Void, Error>) {
        self.result = result
    }

    func connect() async throws {
        connectCount += 1
        try result.get()
    }

    func send(_ frame: Frame) async throws {}

    func disconnect() async {
        disconnectCount += 1
    }

    func counts() -> (connect: Int, disconnect: Int) {
        (connectCount, disconnectCount)
    }
}
