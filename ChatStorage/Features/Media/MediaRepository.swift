import AVFoundation
import Foundation

struct MediaPlayback: Equatable, Sendable {
    let fileId: Int64
    let playURL: URL
    let fileSize: Int64?
    let mimeType: String
    let expiresInSeconds: Int64
}

enum MediaRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case invalidResponse
    case server(String)
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "媒体服务地址无效"
        case .invalidResponse: "媒体服务响应格式无效"
        case .server(let message): message.isEmpty ? "媒体服务请求失败" : message
        case .notPlayable: "文件不支持在线播放"
        }
    }
}

protocol MediaHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionMediaHTTPClient: MediaHTTPClient, Sendable {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    // [修改] URLSession 默认不信任本地 CA，媒体接口必须复用 Socket 的严格证书校验。
    init() {
        let configuration = Self.makeConfiguration()
        self.session = URLSession(
            configuration: configuration,
            delegate: PinnedMediaSessionDelegate(),
            delegateQueue: nil
        )
    }

    // [修改] 媒体 HTTPS 明确锁定 TLS 1.2 以上，和控制/上传/下载 Socket 保持一致。
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw MediaRepositoryError.invalidResponse }
        return (data, httpResponse)
    }
}

// [修改] AVPlayer 和 AVAssetImageGenerator 不走 URLSessionDelegate，单独给 AVAsset 接入同一严格 CA 校验。
final class PinnedMediaAsset: @unchecked Sendable {
    let asset: AVURLAsset
    let resourceLoaderDelegate: PinnedMediaResourceLoaderDelegate
    private let delegateQueue: DispatchQueue

    init?(url: URL) {
        guard url.scheme?.lowercased() == TransportSecurity.mediaScheme,
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else {
            return nil
        }
        asset = AVURLAsset(url: url)
        resourceLoaderDelegate = PinnedMediaResourceLoaderDelegate(expectedHost: host)
        delegateQueue = DispatchQueue(label: "com.alibaba.chatstorage.media-resource-loader.\(UUID().uuidString)")
        // AVAssetResourceLoader 对 delegate 是弱引用，当前包装对象负责在播放/缩略图生命周期内强持有。
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: delegateQueue)
    }

    func makePlayer() -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}

// [修改] 只处理服务端证书挑战；主机必须等于播放 URL 主机，并复用应用内置 CA 的严格信任链。
final class PinnedMediaResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        guard authenticationChallenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return false
        }
        guard authenticationChallenge.protectionSpace.host.caseInsensitiveCompare(expectedHost) == .orderedSame,
              let trust = authenticationChallenge.protectionSpace.serverTrust else {
            authenticationChallenge.sender?.cancel(authenticationChallenge)
            return true
        }

        if TransportSecurity.evaluateServerTrust(trust, expectedHost: expectedHost) {
            authenticationChallenge.sender?.use(URLCredential(trust: trust), for: authenticationChallenge)
        } else {
            authenticationChallenge.sender?.cancel(authenticationChallenge)
        }
        return true
    }
}

// [修改] 仅处理服务端证书挑战，其他鉴权类型继续交给系统默认流程。
private final class PinnedMediaSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let accepted = TransportSecurity.evaluateServerTrust(
            trust,
            expectedHost: challenge.protectionSpace.host
        )
        completionHandler(
            accepted ? .useCredential : .cancelAuthenticationChallenge,
            accepted ? URLCredential(trust: trust) : nil
        )
    }
}

protocol MediaPlaybackProviding: Sendable {
    func playback(fileId: Int64, username: String) async throws -> MediaPlayback
}

actor RemoteMediaRepository: MediaPlaybackProviding {
    private let configuration: ServerConfiguration
    private let transferTokenProvider: @Sendable () -> String
    private let client: any MediaHTTPClient

    init(
        configuration: ServerConfiguration,
        transferToken: String,
        client: any MediaHTTPClient = URLSessionMediaHTTPClient()
    ) {
        self.configuration = configuration
        let token = transferToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transferTokenProvider = { token }
        self.client = client
    }

    // [修改] 会话恢复更新共享凭据后，媒体请求和文件传输立即使用同一份新 token。
    init(
        configuration: ServerConfiguration,
        credentialStore: TransferCredentialStore,
        client: any MediaHTTPClient = URLSessionMediaHTTPClient()
    ) {
        self.configuration = configuration
        self.transferTokenProvider = {
            credentialStore.current().transferToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.client = client
    }

    // [修改] 真机不能使用服务端返回的 localhost，统一替换为当前服务器配置主机。
    func playback(fileId: Int64, username: String) async throws -> MediaPlayback {
        let transferToken = transferTokenProvider()
        guard fileId > 0, !transferToken.isEmpty else {
            throw MediaRepositoryError.invalidRequest
        }
        guard let requestURL = playbackRequestURL(fileId: fileId) else {
            throw MediaRepositoryError.invalidRequest
        }
        var request = URLRequest(url: requestURL)
        // [修改] 媒体身份通过 Authorization 传递，禁止把可伪造的 userName 当作鉴权依据。
        request.setValue("Bearer \(transferToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw MediaRepositoryError.server("媒体服务返回 HTTP \(response.statusCode)")
        }
        let envelope: MediaEnvelope
        do { envelope = try ProtocolJSON.decoder().decode(MediaEnvelope.self, from: data) }
        catch { throw MediaRepositoryError.invalidResponse }
        guard envelope.code == 200, let value = envelope.data else {
            throw MediaRepositoryError.server(envelope.message)
        }
        guard value.playable != false else { throw MediaRepositoryError.notPlayable }
        guard let rawURL = URL(string: value.playUrl), let normalized = normalize(rawURL) else {
            throw MediaRepositoryError.invalidResponse
        }
        return MediaPlayback(
            fileId: value.fileId,
            playURL: normalized,
            fileSize: value.fileSize,
            mimeType: value.mimeType ?? "",
            expiresInSeconds: value.expiresIn
        )
    }

    private func playbackRequestURL(fileId: Int64) -> URL? {
        var components = URLComponents()
        components.scheme = TransportSecurity.mediaScheme
        components.host = normalizedConfiguredHost
        components.port = configuration.mediaPort
        components.path = "/media/play-url/\(fileId)"
        return components.url
    }

    private func normalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // [修改] 服务端不得把 HTTPS 播放链路降级为明文 HTTP。
        guard components.scheme?.lowercased() == TransportSecurity.mediaScheme else { return nil }
        guard let responseHost = components.host?.lowercased() else { return nil }
        let configuredHost = normalizedConfiguredHost.lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(responseHost) {
            components.host = normalizedConfiguredHost
        } else if responseHost != configuredHost {
            // [修改] 播放流只能回到当前服务器，拒绝服务端把 AVPlayer 重定向到外部主机。
            return nil
        }
        guard components.port == nil || components.port == configuration.mediaPort else { return nil }
        if components.port == nil { components.port = configuration.mediaPort }
        return components.url
    }

    private var normalizedConfiguredHost: String {
        configuration.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

private struct MediaEnvelope: Decodable {
    let code: Int
    let message: String
    let data: MediaValue?

    private enum CodingKeys: String, CodingKey { case code, message, msg, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(Int.self, forKey: .code)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? values.decodeIfPresent(String.self, forKey: .msg)
            ?? ""
        data = try values.decodeIfPresent(MediaValue.self, forKey: .data)
    }
}

private struct MediaValue: Decodable {
    let playUrl: String
    let fileId: Int64
    let fileSize: Int64?
    let mimeType: String?
    let expiresIn: Int64
    let playable: Bool?
}
