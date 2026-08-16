import XCTest
@testable import ChatStorage

final class MediaRepositoryTests: XCTestCase {
    func testPlaybackUsesMediaPortAndNormalizesLoopbackURL() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"https://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
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
        // [修改] userName 不再放入查询参数，服务端只从签名传输令牌派生身份。
        XCTAssertEqual(requestURL.absoluteString, "https://192.168.1.8:10188/media/play-url/77")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-transfer-token")
        XCTAssertEqual(playback.playURL.scheme, "https")
        XCTAssertEqual(playback.playURL.host, "192.168.1.8")
        XCTAssertEqual(playback.mimeType, "video/mp4")
    }

    func testPlaybackRejectsPlainHTTPStreamURL() async throws {
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"http://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
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

    // [修改] 播放地址只能指向当前配置服务器，禁止把 AVPlayer 引到任意外部 HTTPS 主机。
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

    // [修改] 媒体 HTTPS 与 Socket 一样锁定 TLS 1.2 以上，不能依赖 ATS 的隐式行为。
    func testMediaSessionConfigurationRequiresTLS12OrLater() {
        let configuration = URLSessionMediaHTTPClient.makeConfiguration()

        XCTAssertEqual(configuration.tlsMinimumSupportedProtocolVersion, .TLSv12)
    }

    // [修改] AVPlayer/AVAssetImageGenerator 使用的资源加载器必须持有严格 CA 委托和当前主机名。
    func testPinnedMediaAssetRetainsStrictTrustDelegateForStreamHost() throws {
        let url = try XCTUnwrap(URL(string: "https://192.168.1.8:10188/media/stream/77?token=x"))
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
        let response = Data(#"{"code":200,"message":"ok","data":{"playUrl":"https://127.0.0.1:10188/media/stream/77?token=x","fileId":77,"fileSize":100,"mimeType":"video/mp4","expiresIn":300,"playable":true}}"#.utf8)
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
