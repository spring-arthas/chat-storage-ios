import XCTest
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
}
