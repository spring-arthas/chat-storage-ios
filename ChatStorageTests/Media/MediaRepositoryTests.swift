import XCTest
@testable import ChatStorage

final class MediaRepositoryTests: XCTestCase {
    func testPlaybackUsesMediaPortAndNormalizesLoopbackURL() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"http://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
        let client = MediaHTTPClientSpy(responseData: response)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: client
        )

        let playback = try await repository.playback(fileId: 77, username: "alice")

        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        let requestURL = try XCTUnwrap(request.url)
        XCTAssertEqual(requestURL.absoluteString, "http://192.168.1.8:10188/media/play-url/77?userName=alice")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-transfer-token")
        XCTAssertEqual(playback.playURL.scheme, "http")
        XCTAssertEqual(playback.playURL.host, "192.168.1.8")
        XCTAssertEqual(playback.mimeType, "video/mp4")
    }

    func testPlaybackRejectsUnsupportedStreamURL() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"ftp://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        do {
            _ = try await repository.playback(fileId: 77, username: "alice")
            XCTFail("服务端返回明文播放地址时必须拒绝")
        } catch let error as MediaRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    // 非 HTTP 媒体地址仍必须拒绝。
    func testPlaybackRejectsHTTPSStreamURLFromDifferentHost() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"https://media.attacker.example:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        do {
            _ = try await repository.playback(fileId: 77, username: "alice")
            XCTFail("跨主机播放地址必须拒绝")
        } catch let error as MediaRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPlaybackNormalizesDifferentLANHostToConfiguredHost() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"http://192.168.0.102:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.0.101"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        let playback = try await repository.playback(fileId: 77, username: "alice")

        // [修改] 服务端广告的其它主机名必须统一替换为配置主机：真机只能到达 /media/play-url
        // 请求所使用的配置主机，绝不能用服务端自己可达的内网 / VPN 地址。
        XCTAssertEqual(playback.playURL.absoluteString, "http://192.168.0.101:10188/media/stream/77?token=x")
    }

    func testMediaSessionConfigurationUsesIndependentTimeouts() {
        let configuration = URLSessionMediaHTTPClient.makeConfiguration()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    // [修改] AVPlayer/AVAssetImageGenerator 使用的资源加载器必须持有严格 CA 委托和当前主机名。
    func testPinnedMediaAssetRetainsStrictTrustDelegateForStreamHost() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.1.8:10188/media/stream/77?token=x"))
        let pinnedAsset = try XCTUnwrap(PinnedMediaAsset(url: url))

        XCTAssertTrue(pinnedAsset.asset.resourceLoader.delegate === pinnedAsset.resourceLoaderDelegate)
        XCTAssertEqual(pinnedAsset.resourceLoaderDelegate.expectedHost, "192.168.1.8")
    }

    func testPlaybackRejectsMissingTransferTokenBeforeSendingRequest() async throws {
        let client = MediaHTTPClientSpy(responseData: Data())
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "  ",
            client: client
        )

        do {
            _ = try await repository.playback(fileId: 77, username: "alice")
            XCTFail("缺少传输令牌时必须拒绝播放地址请求")
        } catch let error as MediaRepositoryError {
            XCTAssertEqual(error, .invalidRequest)
        }
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // [修改] 媒体地址请求和上传下载共用可更新凭据，令牌刷新后下一次请求立即使用新值。
    func testPlaybackUsesLatestCredentialStoreToken() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"http://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
        let client = MediaHTTPClientSpy(responseData: response)
        let credentials = TransferCredentialStore(
            identity: TransferIdentity(userId: 7, username: "alice", transferToken: "old-token")
        )
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            credentialStore: credentials,
            client: client
        )
        credentials.update(
            TransferIdentity(userId: 7, username: "alice", transferToken: "new-token")
        )

        _ = try await repository.playback(fileId: 77, username: "alice")

        let requests = await client.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
    }

    func testPlaybackAcceptsLegacyStringFieldsAndAliases() async throws {
        let response = Data(#"{"code":"200","message":"ok","data":{"url":"http://127.0.0.1:10188/media/stream/77?token=x","fileID":"77","size":"4294967296","contentType":"video/mp4","expiresInSeconds":"300","isPlayable":"true"}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        let playback = try await repository.playback(fileId: 77, username: "alice")

        XCTAssertEqual(playback.fileId, 77)
        XCTAssertEqual(playback.fileSize, 4_294_967_296)
        XCTAssertEqual(playback.expiresInSeconds, 300)
        XCTAssertEqual(playback.playURL.host, "192.168.1.8")
    }

    func testPlaybackHandlesSparseNotPlayableResponseBeforeSuccessFieldValidation() async throws {
        let response = Data(#"{"code":200,"message":"该文件不能播放","data":{"playable":false}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        do {
            _ = try await repository.playback(fileId: 77, username: "alice")
            XCTFail("不可播放响应必须保留服务端业务错误")
        } catch let error as MediaRepositoryError {
            XCTAssertEqual(error, .server("该文件不能播放"))
        }
    }

    func testPlaybackUsesRequestedFileIdAndDefaultExpiryWhenOptionalMetadataIsMissing() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"http://127.0.0.1:10188/media/stream/77?token=x","playable":true}}"#.utf8)
        let repository = RemoteMediaRepository(
            configuration: try ServerConfiguration(host: "192.168.1.8"),
            transferToken: "signed-transfer-token",
            client: MediaHTTPClientSpy(responseData: response)
        )

        let playback = try await repository.playback(fileId: 77, username: "alice")

        XCTAssertEqual(playback.fileId, 77)
        XCTAssertEqual(playback.expiresInSeconds, 300)
    }
}

private actor MediaHTTPClientSpy: MediaHTTPClient {
    private let responseData: Data
    private(set) var requests: [URLRequest] = []

    init(responseData: Data) { self.responseData = responseData }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        requests.append(request)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (responseData, response)
    }
}
