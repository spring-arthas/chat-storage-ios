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

    // The media gateway is the server's plain HTTP Range endpoint.
    init() {
        let configuration = Self.makeConfiguration()
        self.session = URLSession(
            configuration: configuration,
            delegate: PinnedMediaSessionDelegate(),
            delegateQueue: nil
        )
    }

    // Keep the media request timeouts independent from the file-transfer
    // sockets. The endpoint must return a small playback descriptor quickly;
    // AVPlayer handles the subsequent Range requests.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw MediaRepositoryError.invalidResponse }
        return (data, httpResponse)
    }
}

// AVPlayer and AVAssetImageGenerator use this wrapper so the resource loader
// delegate remains alive for the lifetime of the remote asset. The media
// gateway is HTTP, so no TLS challenge handling is needed in normal playback.
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

// Retained for deployments that expose a TLS media gateway; HTTP playback
// simply never invokes this challenge callback.
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

// Retained for deployments that expose a TLS media gateway.
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
        guard let requestURL = playbackRequestURL(fileId: fileId, username: username) else {
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
        do {
            envelope = try ProtocolJSON.decoder().decode(MediaEnvelope.self, from: data)
        } catch {
            print("[Media] play-url JSON decode failed: \(error); body=\(Self.redactedBody(data))")
            throw MediaRepositoryError.invalidResponse
        }
        guard envelope.code == 200 else {
            throw MediaRepositoryError.server(envelope.message)
        }
        guard let value = envelope.data else {
            print("[Media] play-url response has no data: body=\(Self.redactedBody(data))")
            throw MediaRepositoryError.invalidResponse
        }
        if value.playable == false {
            let message = envelope.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty, message.caseInsensitiveCompare("ok") != .orderedSame {
                throw MediaRepositoryError.server(message)
            }
            throw MediaRepositoryError.notPlayable
        }
        guard let playUrl = value.playUrl,
              let rawURL = URL(string: playUrl),
              let normalized = normalize(rawURL) else {
            print("[Media] play-url response has invalid playUrl: \(Self.redactedURL(value.playUrl)); body=\(Self.redactedBody(data))")
            throw MediaRepositoryError.invalidResponse
        }
        // [修改] 输出服务端广告地址与最终播放地址，便于真机判断连不上的是哪一段。
        print("[Media] play-url resolved: raw=\(Self.redactedURL(value.playUrl)) -> stream=\(Self.redactedURL(normalized.absoluteString))")
        return MediaPlayback(
            fileId: value.fileId ?? fileId,
            playURL: normalized,
            fileSize: value.fileSize,
            mimeType: value.mimeType ?? "",
            // Older servers omit the expiry field even though the URL is
            // usable. Keep the URL playable and refresh it conservatively.
            expiresInSeconds: max(value.expiresIn ?? 300, 1)
        )
    }

    private func playbackRequestURL(fileId: Int64, username: String) -> URL? {
        var components = URLComponents()
        components.scheme = TransportSecurity.mediaScheme
        components.host = normalizedConfiguredHost
        components.port = configuration.mediaPort
        components.path = "/media/play-url/\(fileId)"
        // Keep the request contract aligned with the macOS and Android
        // clients. The media gateway uses this identity when creating the
        // short-lived stream session; the bearer token remains for servers
        // that additionally enforce transfer-token authentication.
        components.queryItems = [URLQueryItem(name: "userName", value: username)]
        return components.url
    }

    private func normalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Only accept the scheme exposed by the configured media gateway.
        guard components.scheme?.lowercased() == TransportSecurity.mediaScheme else { return nil }
        guard components.host != nil else { return nil }
        // [修改] 真机统一使用当前配置主机：/media/play-url 请求本身就走配置主机，媒体流
        // 也必须与之一致。服务端在多网卡 / VPN 环境常把 play-url 广告成自己可达的内网或
        // VPN 地址，手机无法到达，必须替换回配置主机。
        if components.host?.lowercased() != normalizedConfiguredHost.lowercased() {
            components.host = normalizedConfiguredHost
        }
        guard components.port == nil || components.port == configuration.mediaPort else { return nil }
        if components.port == nil { components.port = configuration.mediaPort }
        return components.url
    }

    private var normalizedConfiguredHost: String {
        configuration.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func redactedBody(_ data: Data) -> String {
        let body = String(decoding: data, as: UTF8.self)
        let limited = body.count <= 2_000 ? body : String(body.prefix(2_000)) + "..."
        return redactSecrets(in: limited)
    }

    private static func redactedURL(_ value: String?) -> String {
        guard let value else { return "nil" }
        return redactSecrets(in: value)
    }

    private static func redactSecrets(in value: String) -> String {
        value.replacingOccurrences(
            of: #"([?&](?:token|access_token|signature)=)[^&#\"}]+"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
    }
}

private struct MediaEnvelope: Decodable {
    let code: Int
    let message: String
    let data: MediaValue?

    private enum CodingKeys: String, CodingKey { case code, message, msg, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let numericCode = try? values.decode(Int.self, forKey: .code) {
            code = numericCode
        } else if let stringCode = try? values.decode(String.self, forKey: .code),
                  let numericCode = Int(stringCode) {
            code = numericCode
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: values,
                debugDescription: "Media response code is missing or invalid"
            )
        }
        message = (try? values.decodeIfPresent(String.self, forKey: .message))
            ?? (try? values.decodeIfPresent(String.self, forKey: .msg))
            ?? ""
        data = try values.decodeIfPresent(MediaValue.self, forKey: .data)
    }
}

private struct MediaValue: Decodable {
    let playUrl: String?
    let fileId: Int64?
    let fileSize: Int64?
    let mimeType: String?
    let expiresIn: Int64?
    let playable: Bool?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: MediaCodingKey.self)
        playUrl = try values.firstString(["playUrl", "playURL", "url"])
        fileId = values.firstLossyInt64(["fileId", "fileID", "id"])
        fileSize = values.firstLossyInt64(["fileSize", "size"])
        mimeType = try values.firstString(["mimeType", "contentType"])
        expiresIn = values.firstLossyInt64(["expiresIn", "expiresInSeconds"])
        playable = values.firstLossyBool(["playable", "isPlayable"])
    }
}

private struct MediaCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == MediaCodingKey {
    func firstString(_ names: [String]) throws -> String? {
        for name in names {
            let key = MediaCodingKey(name)
            guard contains(key) else { continue }
            if let value = try decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    func firstLossyInt64(_ names: [String]) -> Int64? {
        for name in names {
            let key = MediaCodingKey(name)
            guard contains(key) else { continue }
            if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    func firstLossyBool(_ names: [String]) -> Bool? {
        for name in names {
            let key = MediaCodingKey(name)
            guard contains(key) else { continue }
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "y", "1": return true
                case "false", "no", "n", "0": return false
                default: continue
                }
            }
        }
        return nil
    }
}
