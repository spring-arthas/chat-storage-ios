import CryptoKit
import Foundation
import Network
import Photos

struct TransferIdentity: Equatable, Sendable {
    let userId: Int64
    let username: String
    let transferToken: String
}

// [修改] 同一账号运行时复用 manager，登录恢复后原子替换 transferToken，后续任务读取最新凭据。
final class TransferCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: TransferIdentity

    init(identity: TransferIdentity) {
        self.identity = identity
    }

    func current() -> TransferIdentity {
        lock.withLock { identity }
    }

    func update(_ identity: TransferIdentity) {
        lock.withLock { self.identity = identity }
    }
}

struct TransferProgress: Equatable, Sendable {
    let transferredBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(transferredBytes) / Double(totalBytes), 0), 1)
    }
}

struct UploadCommand: Equatable, Sendable {
    let configuration: ServerConfiguration
    let identity: TransferIdentity
    let taskId: String
    let targetDirectoryId: Int64
    let requestedOffset: Int64
    let knownMD5: String?
    let uploadPurpose: String
    let batchId: String?

    init(
        configuration: ServerConfiguration,
        identity: TransferIdentity,
        taskId: String,
        targetDirectoryId: Int64,
        requestedOffset: Int64 = 0,
        knownMD5: String? = nil,
        uploadPurpose: String = "CLOUD_FILE",
        batchId: String? = nil
    ) {
        self.configuration = configuration
        self.identity = identity
        self.taskId = taskId
        self.targetDirectoryId = targetDirectoryId
        self.requestedOffset = requestedOffset
        self.knownMD5 = knownMD5
        self.uploadPurpose = uploadPurpose
        self.batchId = batchId
    }
}

struct UploadResult: Equatable, Sendable {
    let fileId: Int64
    let uploadedBytes: Int64
}

struct DownloadCommand: Equatable, Sendable {
    let configuration: ServerConfiguration
    let identity: TransferIdentity
    let taskId: String
    let remoteFileId: Int64
    let expectedFileSize: Int64
}

struct DownloadResult: Equatable, Sendable {
    let downloadedBytes: Int64
    // [修改] 下载管理器可能原子调整重名目标，调用方必须拿到最终落盘路径。
    let destinationURL: URL
}

struct RangePullCommand: Equatable, Sendable {
    let configuration: ServerConfiguration
    let identity: TransferIdentity
    let taskId: String
    let remoteFileId: Int64
    let startOffset: Int64
    let length: Int64
}

struct RangePullResult: Equatable, Sendable {
    let data: Data
    let fileSize: Int64
    let startOffset: Int64
    let nextOffset: Int64
    let isEOF: Bool
}

// [修改] 文件传输连接和空闲窗口与 macOS 对齐，并允许测试注入短超时。
struct TransferTimeoutConfiguration: Equatable, Sendable {
    let connect: Duration
    let idle: Duration

    init(connect: Duration = .seconds(15), idle: Duration = .seconds(45)) {
        self.connect = connect
        self.idle = idle
    }
}

enum FileTransferError: Error, Equatable, LocalizedError, Sendable {
    case invalidTaskId
    case invalidDirectoryId
    case invalidFileId
    case unreadableSource
    case invalidResponse(String)
    case server(String)
    case incompleteTransfer(expected: Int64, actual: Int64)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidTaskId:
            return "传输任务 ID 无效"
        case .invalidDirectoryId:
            return "目标目录无效"
        case .invalidFileId:
            return "文件 ID 无效"
        case .unreadableSource:
            return "无法读取所选文件"
        case .invalidResponse(let message), .server(let message):
            // [修改] 服务端空 message 和内部空描述统一回退，避免传输中心显示空白失败原因。
            let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "文件传输失败" : value
        case .incompleteTransfer(let expected, let actual):
            return "文件传输不完整，预期 \(expected) 字节，实际 \(actual) 字节"
        case .timedOut(let operation):
            return "\(operation)超时"
        }
    }
}

protocol TransferFrameTransport: Sendable {
    func connect(host: String, port: Int) async throws
    func send(_ frame: Frame) async throws
    func receive() async throws -> Frame
    func close() async
}

protocol FileUploading: Sendable {
    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult
}

// 相册视频不生成 App 本地副本；先从 Photos 资源流计算元数据，再重新按块读取并发送。
struct PhotoLibraryUploadMetadata: Equatable, Sendable {
    let fileSize: Int64
    let md5: String
}

protocol PhotoLibraryUploading: Sendable {
    func uploadPhotoLibraryVideo(
        command: UploadCommand,
        assetLocalIdentifier: String,
        fileName: String,
        fileType: String,
        knownFileSize: Int64?,
        onMetadataComputed: @escaping @Sendable (PhotoLibraryUploadMetadata) async throws -> Void,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult
}

protocol FileDownloading: Sendable {
    func download(
        command: DownloadCommand,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> DownloadResult
}

protocol FileRangePulling: Sendable {
    func pull(command: RangePullCommand) async throws -> RangePullResult
}

actor NWTransferFrameTransport: TransferFrameTransport {
    private let queue = DispatchQueue(label: "com.alibaba.chatstorage.transfer-connection")
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var decoder = FrameStreamDecoder()
    private var bufferedFrames: [Frame] = []

    func connect(host: String, port: Int) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ConnectionError.invalidPort(port)
        }

        // 与 macOS 客户端及服务端 10087/10088 保持一致：文件传输使用普通 TCP 帧连接。
        let candidate = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: TransportSecurity.makePlainTCPParameters()
        )
        connection = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let candidate else { return }
            Task { await self?.handle(state: state, for: candidate) }
        }
        // 先登记 continuation，再启动连接。NWConnection 在本机或局域网环境下
        // 可能在 start 返回前就发出状态回调；若先 start，ready/failed 回调会找不到
        // continuation，下载任务就会永久停在 running 且进度为 0。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            candidate.start(queue: queue)
        }
    }

    func send(_ frame: Frame) async throws {
        guard let connection, connection.state == .ready else {
            throw ConnectionError.notConnected
        }
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Frame {
        while bufferedFrames.isEmpty {
            let chunk = try await receiveChunk()
            bufferedFrames.append(contentsOf: try decoder.append(chunk))
        }
        return bufferedFrames.removeFirst()
    }

    func close() async {
        let active = connection
        connection = nil
        connectContinuation?.resume(throwing: ConnectionError.disconnected)
        connectContinuation = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
        bufferedFrames.removeAll()
        decoder = FrameStreamDecoder()
    }

    private func handle(state: NWConnection.State, for candidate: NWConnection) {
        guard connection === candidate else { return }
        switch state {
        case .ready:
            connectContinuation?.resume()
            connectContinuation = nil
        case .failed(let error):
            connection = nil
            connectContinuation?.resume(throwing: ConnectionError.failed(error.localizedDescription))
            connectContinuation = nil
        case .cancelled:
            connection = nil
            connectContinuation?.resume(throwing: ConnectionError.disconnected)
            connectContinuation = nil
        default:
            break
        }
    }

    private func receiveChunk() async throws -> Data {
        guard let connection, connection.state == .ready else {
            throw ConnectionError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ConnectionError.failed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ConnectionError.disconnected)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

// [修改] 所有 connect/send/receive 统一套超时；超时或取消时先关闭底层连接，确保阻塞调用能退出。
private struct TimedTransferFrameTransport: TransferFrameTransport {
    let base: any TransferFrameTransport
    let timeouts: TransferTimeoutConfiguration

    func connect(host: String, port: Int) async throws {
        try await withTransferTimeout(label: "连接服务器", duration: timeouts.connect, close: { await base.close() }) {
            try await base.connect(host: host, port: port)
        }
    }

    func send(_ frame: Frame) async throws {
        try await withTransferTimeout(label: "发送传输数据", duration: timeouts.idle, close: { await base.close() }) {
            try await base.send(frame)
        }
    }

    func receive() async throws -> Frame {
        try await receive(timeout: timeouts.idle)
    }

    // [修改] 上传最终 ACK 可使用独立窗口，普通握手和进度响应仍受 idle 限制。
    func receive(timeout: Duration) async throws -> Frame {
        try await withTransferTimeout(label: "等待服务器响应", duration: timeout, close: { await base.close() }) {
            try await base.receive()
        }
    }

    func close() async { await base.close() }
}

private func withTransferTimeout<Value: Sendable>(
    label: String,
    duration: Duration,
    close: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw FileTransferError.timedOut(label)
            }
            do {
                guard let value = try await group.next() else {
                    throw FileTransferError.invalidResponse("传输操作提前结束")
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                await close()
                while let _ = await group.nextResult() {}
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    } onCancel: {
        Task { await close() }
    }
}

struct FileUploadEngine: Sendable {
    private let transportFactory: @Sendable () -> any TransferFrameTransport
    private let timeouts: TransferTimeoutConfiguration

    init(
        transportFactory: @escaping @Sendable () -> any TransferFrameTransport = { NWTransferFrameTransport() },
        timeouts: TransferTimeoutConfiguration = .init()
    ) {
        self.transportFactory = transportFactory
        self.timeouts = timeouts
    }

    func upload(
        command: UploadCommand,
        sourceURL: URL,
        onMD5Computed: @escaping @Sendable (String) async throws -> Void = { _ in },
        onProgress: @escaping @Sendable (TransferProgress) async -> Void = { _ in }
    ) async throws -> UploadResult {
        guard !command.taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTransferError.invalidTaskId
        }
        guard command.targetDirectoryId > 0 else { throw FileTransferError.invalidDirectoryId }

        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        guard let fileSizeValue = resourceValues.fileSize else { throw FileTransferError.unreadableSource }
        let fileSize = Int64(fileSizeValue)
        let fileName = resourceValues.name ?? sourceURL.lastPathComponent
        let fileType = sourceURL.pathExtension.lowercased()
        let md5 = try command.knownMD5?.trimmedNonEmpty ?? computeMD5(of: sourceURL)
        // [修改] 摘要算完立即通知任务层持久化，网络失败后的重试直接复用。
        try await onMD5Computed(md5)
        try Task.checkCancellation()
        let transport = TimedTransferFrameTransport(base: transportFactory(), timeouts: timeouts)

        // [修改] Task 取消时主动关闭传输连接，解除正在等待服务端 ACK 的 receive。
        return try await withTaskCancellationHandler {
            do {
                try await transport.connect(host: command.configuration.host, port: command.configuration.uploadPort)
                let result = try await performUpload(
                    command: command,
                    sourceURL: sourceURL,
                    fileName: fileName,
                    fileType: fileType,
                    fileSize: fileSize,
                    md5: md5,
                    transport: transport,
                    onProgress: onProgress
                )
                await transport.close()
                return result
            } catch {
                await transport.close()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }

    func uploadPhotoLibraryVideo(
        command: UploadCommand,
        assetLocalIdentifier: String,
        fileName: String,
        fileType: String,
        knownFileSize: Int64? = nil,
        onMetadataComputed: @escaping @Sendable (PhotoLibraryUploadMetadata) async throws -> Void = { _ in },
        onProgress: @escaping @Sendable (TransferProgress) async -> Void = { _ in }
    ) async throws -> UploadResult {
        guard !command.taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTransferError.invalidTaskId
        }
        guard command.targetDirectoryId > 0 else { throw FileTransferError.invalidDirectoryId }

        let source = try PhotoLibraryVideoSource(assetLocalIdentifier: assetLocalIdentifier)
        let metadata: PhotoLibraryUploadMetadata
        if let md5 = command.knownMD5?.trimmedNonEmpty, let knownFileSize, knownFileSize > 0 {
            // 重试已持久化过完整元数据，无需为 32 GiB 视频额外再扫描一次。
            metadata = .init(fileSize: knownFileSize, md5: md5)
        } else {
            metadata = try await source.metadata()
        }
        try await onMetadataComputed(metadata)
        try Task.checkCancellation()

        let transport = TimedTransferFrameTransport(base: transportFactory(), timeouts: timeouts)
        return try await withTaskCancellationHandler {
            do {
                try await transport.connect(host: command.configuration.host, port: command.configuration.uploadPort)
                let result = try await performPhotoLibraryUpload(
                    command: command,
                    source: source,
                    fileName: fileName,
                    fileType: fileType,
                    metadata: metadata,
                    transport: transport,
                    onProgress: onProgress
                )
                await transport.close()
                return result
            } catch {
                await transport.close()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }

    private func performUpload(
        command: UploadCommand,
        sourceURL: URL,
        fileName: String,
        fileType: String,
        fileSize: Int64,
        md5: String,
        transport: TimedTransferFrameTransport,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        let resumeRequest = UploadResumeRequest(
            fileSize: fileSize,
            dirId: command.targetDirectoryId,
            fileName: fileName,
            userId: command.identity.userId,
            userName: command.identity.username,
            taskId: command.taskId,
            md5: md5,
            startOffset: command.requestedOffset,
            transferToken: command.identity.transferToken,
            uploadPurpose: command.uploadPurpose,
            connectionReuse: false,
            batchId: command.batchId
        )
        let resumeFrame = Frame(type: .resumeCheck, payload: try ProtocolJSON.encoder().encode(resumeRequest))
        let resume = try await requestAcknowledgement(
            resumeFrame,
            expecting: .resumeAcknowledgement,
            taskId: command.taskId,
            transport: transport
        )

        if resume.status == "complete" {
            guard let fileId = resume.fileId, fileId > 0 else {
                throw FileTransferError.invalidResponse("服务端未返回有效文件 ID")
            }
            await onProgress(TransferProgress(transferredBytes: fileSize, totalBytes: fileSize))
            return UploadResult(fileId: fileId, uploadedBytes: fileSize)
        }

        var offset: Int64
        switch resume.status {
        case "resume":
            offset = try validatedOffset(resume.uploadedSize ?? 0, maximum: fileSize)
        case "new":
            let metadata = UploadMetadataRequest(
                md5: md5,
                fileName: fileName,
                fileSize: fileSize,
                fileType: fileType,
                dirId: command.targetDirectoryId,
                userId: command.identity.userId,
                userName: command.identity.username,
                taskId: command.taskId,
                transferToken: command.identity.transferToken,
                uploadPurpose: command.uploadPurpose,
                connectionReuse: false,
                batchId: command.batchId
            )
            let metadataFrame = Frame(type: .metadata, payload: try ProtocolJSON.encoder().encode(metadata))
            let ready = try await requestAcknowledgement(
                metadataFrame,
                expecting: .acknowledgement,
                taskId: command.taskId,
                transport: transport
            )
            guard ready.status == "ready" else {
                throw FileTransferError.server(ready.message ?? "服务端未准备好接收文件")
            }
            offset = try validatedOffset(ready.uploadedSize ?? 0, maximum: fileSize)
        default:
            throw FileTransferError.server(resume.message ?? "未知上传断点状态")
        }

        await onProgress(TransferProgress(transferredBytes: offset, totalBytes: fileSize))
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var lastAcknowledgedOffset = offset
        var rewindCount = 0

        while offset < fileSize {
            try Task.checkCancellation()
            let count = Int(min(Int64(Self.chunkSize), fileSize - offset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw FileTransferError.incompleteTransfer(expected: fileSize, actual: offset)
            }
            let nextOffset = offset + Int64(chunk.count)
            let needsAcknowledgement = nextOffset == fileSize || nextOffset - lastAcknowledgedOffset >= Self.acknowledgementWindow
            var flags = Frame.transferHasOffsetFlag
            if needsAcknowledgement { flags |= Frame.transferNeedsAcknowledgementFlag }
            let dataFrame = Frame(type: .data, flags: flags, payload: offsetPayload(offset: offset, data: chunk))

            if needsAcknowledgement {
                let progress = try await requestAcknowledgement(
                    dataFrame,
                    expecting: .acknowledgement,
                    taskId: command.taskId,
                    transport: transport
                )
                guard progress.status == "progress" else {
                    throw FileTransferError.server(progress.message ?? "服务端上传进度确认失败")
                }
                let confirmedOffset = try validatedOffset(progress.uploadedSize ?? 0, maximum: nextOffset)
                if confirmedOffset < nextOffset {
                    rewindCount += 1
                    guard rewindCount <= Self.maximumRewindCount else {
                        throw FileTransferError.server("服务端进度多次落后，上传已停止")
                    }
                    offset = confirmedOffset
                    lastAcknowledgedOffset = confirmedOffset
                    try handle.seek(toOffset: UInt64(confirmedOffset))
                    await onProgress(TransferProgress(transferredBytes: offset, totalBytes: fileSize))
                    continue
                }
                rewindCount = 0
                lastAcknowledgedOffset = confirmedOffset
            } else {
                try await transport.send(dataFrame)
            }

            offset = nextOffset
            await onProgress(TransferProgress(transferredBytes: offset, totalBytes: fileSize))
        }

        let end = Frame(type: .end, payload: try ProtocolJSON.encoder().encode(UploadEndRequest(taskId: command.taskId)))
        let completed = try await requestAcknowledgement(
            end,
            expecting: .acknowledgement,
            taskId: command.taskId,
            transport: transport,
            receiveTimeout: Self.uploadFinalizeTimeout(fileSize: fileSize)
        )
        guard completed.status == "success" else {
            throw FileTransferError.server(completed.message ?? "文件完整性校验失败")
        }
        guard let fileId = completed.fileId, fileId > 0 else {
            throw FileTransferError.invalidResponse("服务端未返回有效文件 ID")
        }
        return UploadResult(fileId: fileId, uploadedBytes: fileSize)
    }

    private func performPhotoLibraryUpload(
        command: UploadCommand,
        source: PhotoLibraryVideoSource,
        fileName: String,
        fileType: String,
        metadata: PhotoLibraryUploadMetadata,
        transport: TimedTransferFrameTransport,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void
    ) async throws -> UploadResult {
        let resumeRequest = UploadResumeRequest(
            fileSize: metadata.fileSize, dirId: command.targetDirectoryId, fileName: fileName,
            userId: command.identity.userId, userName: command.identity.username, taskId: command.taskId,
            md5: metadata.md5, startOffset: command.requestedOffset, transferToken: command.identity.transferToken,
            uploadPurpose: command.uploadPurpose, connectionReuse: false, batchId: command.batchId
        )
        let resume = try await requestAcknowledgement(
            Frame(type: .resumeCheck, payload: try ProtocolJSON.encoder().encode(resumeRequest)),
            expecting: .resumeAcknowledgement, taskId: command.taskId, transport: transport
        )
        if resume.status == "complete" {
            guard let fileId = resume.fileId, fileId > 0 else {
                throw FileTransferError.invalidResponse("服务端未返回有效文件 ID")
            }
            await onProgress(.init(transferredBytes: metadata.fileSize, totalBytes: metadata.fileSize))
            return .init(fileId: fileId, uploadedBytes: metadata.fileSize)
        }

        let initialOffset: Int64
        switch resume.status {
        case "resume":
            initialOffset = try validatedOffset(resume.uploadedSize ?? 0, maximum: metadata.fileSize)
        case "new":
            let request = UploadMetadataRequest(
                md5: metadata.md5, fileName: fileName, fileSize: metadata.fileSize, fileType: fileType,
                dirId: command.targetDirectoryId, userId: command.identity.userId, userName: command.identity.username,
                taskId: command.taskId, transferToken: command.identity.transferToken, uploadPurpose: command.uploadPurpose,
                connectionReuse: false, batchId: command.batchId
            )
            let ready = try await requestAcknowledgement(
                Frame(type: .metadata, payload: try ProtocolJSON.encoder().encode(request)),
                expecting: .acknowledgement, taskId: command.taskId, transport: transport
            )
            guard ready.status == "ready" else {
                throw FileTransferError.server(ready.message ?? "服务端未准备好接收文件")
            }
            initialOffset = try validatedOffset(ready.uploadedSize ?? 0, maximum: metadata.fileSize)
        default:
            throw FileTransferError.server(resume.message ?? "未知上传断点状态")
        }

        await onProgress(.init(transferredBytes: initialOffset, totalBytes: metadata.fileSize))
        var restartOffset = initialOffset
        var rewindCount = 0
        while true {
            var offset = restartOffset
            var lastAcknowledgedOffset = offset
            do {
                try await source.consume(from: offset) { data in
                    var cursor = data.startIndex
                    while cursor < data.endIndex {
                        try Task.checkCancellation()
                        let end = data.index(cursor, offsetBy: min(Self.photoLibraryUploadChunkSize, data.distance(from: cursor, to: data.endIndex)))
                        let chunk = Data(data[cursor..<end])
                        cursor = end
                        let nextOffset = offset + Int64(chunk.count)
                        let needsAcknowledgement = nextOffset == metadata.fileSize || nextOffset - lastAcknowledgedOffset >= Self.photoLibraryAcknowledgementWindow
                        var flags = Frame.transferHasOffsetFlag
                        if needsAcknowledgement { flags |= Frame.transferNeedsAcknowledgementFlag }
                        let frame = Frame(type: .data, flags: flags, payload: offsetPayload(offset: offset, data: chunk))
                        if needsAcknowledgement {
                            let progress = try await requestAcknowledgement(frame, expecting: .acknowledgement, taskId: command.taskId, transport: transport)
                            guard progress.status == "progress" else {
                                throw FileTransferError.server(progress.message ?? "服务端上传进度确认失败")
                            }
                            let confirmed = try validatedOffset(progress.uploadedSize ?? 0, maximum: nextOffset)
                            if confirmed < nextOffset {
                                rewindCount += 1
                                guard rewindCount <= Self.maximumRewindCount else {
                                    throw FileTransferError.server("服务端进度多次落后，上传已停止")
                                }
                                throw PhotoLibraryUploadRewind(offset: confirmed)
                            }
                            lastAcknowledgedOffset = confirmed
                        } else {
                            try await transport.send(frame)
                        }
                        offset = nextOffset
                        await onProgress(.init(transferredBytes: offset, totalBytes: metadata.fileSize))
                    }
                }
                guard offset == metadata.fileSize else {
                    throw FileTransferError.incompleteTransfer(expected: metadata.fileSize, actual: offset)
                }
                break
            } catch let rewind as PhotoLibraryUploadRewind {
                restartOffset = rewind.offset
                await onProgress(.init(transferredBytes: restartOffset, totalBytes: metadata.fileSize))
            }
        }

        let completed = try await requestAcknowledgement(
            Frame(type: .end, payload: try ProtocolJSON.encoder().encode(UploadEndRequest(taskId: command.taskId))),
            expecting: .acknowledgement, taskId: command.taskId, transport: transport,
            receiveTimeout: Self.uploadFinalizeTimeout(fileSize: metadata.fileSize)
        )
        guard completed.status == "success" else {
            throw FileTransferError.server(completed.message ?? "文件完整性校验失败")
        }
        guard let fileId = completed.fileId, fileId > 0 else {
            throw FileTransferError.invalidResponse("服务端未返回有效文件 ID")
        }
        return .init(fileId: fileId, uploadedBytes: metadata.fileSize)
    }

    private func requestAcknowledgement(
        _ frame: Frame,
        expecting expectedType: FrameType,
        taskId: String,
        transport: TimedTransferFrameTransport,
        receiveTimeout: Duration? = nil
    ) async throws -> TransferAcknowledgement {
        try await transport.send(frame)
        let response: Frame
        if let receiveTimeout {
            response = try await transport.receive(timeout: receiveTimeout)
        } else {
            response = try await transport.receive()
        }
        guard response.type == expectedType else {
            throw FileTransferError.invalidResponse("服务端返回了错误的传输帧类型")
        }
        let acknowledgement = try ProtocolJSON.decoder().decode(TransferAcknowledgement.self, from: response.payload)
        if acknowledgement.status == "error" || acknowledgement.status == "fail" {
            throw FileTransferError.server(acknowledgement.message ?? "文件传输失败")
        }
        if let responseTaskId = acknowledgement.taskId, responseTaskId != taskId {
            throw FileTransferError.invalidResponse("服务端传输任务 ID 不匹配")
        }
        return acknowledgement
    }

    private func validatedOffset(_ value: Int64, maximum: Int64) throws -> Int64 {
        guard value >= 0, value <= maximum else {
            throw FileTransferError.invalidResponse("服务端返回的传输偏移无效: \(value)")
        }
        return value
    }

    private func offsetPayload(offset: Int64, data: Data) -> Data {
        var value = UInt64(offset).bigEndian
        var payload = Data(capacity: MemoryLayout<UInt64>.size + data.count)
        withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        payload.append(data)
        return payload
    }

    private func computeMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            // [修改] 大文件摘要计算也响应暂停，避免取消后继续扫描完整文件。
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // [修改] END 后服务端会重读整文件计算 MD5，按 20 MiB/s 估算并限制在 60–600 秒。
    private static func uploadFinalizeTimeout(fileSize: Int64) -> Duration {
        let estimatedHashSeconds = Double(max(0, fileSize)) / Double(20 * 1024 * 1024)
        return .seconds(min(600, max(60, estimatedHashSeconds + 30)))
    }

    private static let chunkSize = 64 * 1024
    private static let acknowledgementWindow: Int64 = 4 * 1024 * 1024
    // 相册零副本路径减少帧数量，32 GiB 视频约 32K 个数据帧；常规文件路径保持既有 64 KiB 兼容参数。
    private static let photoLibraryUploadChunkSize = 1024 * 1024
    private static let photoLibraryAcknowledgementWindow: Int64 = 8 * 1024 * 1024
    private static let maximumRewindCount = 12
}

extension FileUploadEngine: FileUploading {}
extension FileUploadEngine: PhotoLibraryUploading {}

private struct PhotoLibraryUploadRewind: Error {
    let offset: Int64
}

// PHAssetResourceManager 直接交付 Photos 存储中的数据。网络访问明确关闭，因此 iCloud-only 资源不会被
// 下载到 App 或变成本地副本；调用者会得到读取失败并要求用户先在相册中下载该视频。
private final class PhotoLibraryVideoSource: @unchecked Sendable {
    private let assetLocalIdentifier: String

    init(assetLocalIdentifier: String) throws {
        guard !assetLocalIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTransferError.unreadableSource
        }
        self.assetLocalIdentifier = assetLocalIdentifier
    }

    func metadata() async throws -> PhotoLibraryUploadMetadata {
        var digest = Insecure.MD5()
        var size: Int64 = 0
        try await consume { data in
            try Task.checkCancellation()
            digest.update(data: data)
            size += Int64(data.count)
        }
        guard size > 0 else { throw FileTransferError.unreadableSource }
        let md5 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(fileSize: size, md5: md5)
    }

    func consume(from offset: Int64 = 0, _ body: @escaping (Data) async throws -> Void) async throws {
        let resource = try videoResource()
        let pump = PhotoLibraryDataPump()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let requestID = PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in pump.enqueue(data) },
            completionHandler: { error in pump.finish(error: error) }
        )
        pump.setRequestID(requestID)

        do {
            try await withTaskCancellationHandler {
                var remaining = max(0, offset)
                while let delivered = try await pump.next() {
                    defer { pump.release() }
                    if remaining >= Int64(delivered.count) {
                        remaining -= Int64(delivered.count)
                        continue
                    }
                    let start = Int(remaining)
                    remaining = 0
                    try await body(start == 0 ? delivered : Data(delivered.dropFirst(start)))
                }
                guard remaining == 0 else { throw FileTransferError.unreadableSource }
            } onCancel: {
                pump.cancel()
            }
        } catch {
            pump.cancel()
            throw error
        }
    }

    private func videoResource() throws -> PHAssetResource {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil)
        guard let asset = result.firstObject else { throw FileTransferError.unreadableSource }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            throw FileTransferError.unreadableSource
        }
        return resource
    }
}

// Photos 的回调为同步 API；容量限制为两个系统数据包，上传端处理完一个才允许继续交付下一个，避免
// AsyncStream 无界缓存导致大视频在内存里累积。
private final class PhotoLibraryDataPump: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = DispatchSemaphore(value: 2)
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var terminalError: Error?
    private var finished = false
    private var cancelled = false
    private var requestID: PHAssetResourceDataRequestID?

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.withLock {
            self.requestID = requestID
            if cancelled { PHAssetResourceManager.default().cancelDataRequest(requestID) }
        }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        capacity.wait()
        let continuation: CheckedContinuation<Data?, Error>? = lock.withLock {
            guard !cancelled, !finished else {
                capacity.signal()
                return nil
            }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            buffered.append(data)
            return nil
        }
        continuation?.resume(returning: data)
    }

    func finish(error: Error?) {
        let continuation: CheckedContinuation<Data?, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            terminalError = error
            guard buffered.isEmpty, let waiter else { return nil }
            self.waiter = nil
            return waiter
        }
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: nil) }
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data?, Error>? = lock.withLock {
                if !buffered.isEmpty { return .success(buffered.removeFirst()) }
                if let terminalError { return .failure(terminalError) }
                if finished { return .success(nil) }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func release() { capacity.signal() }

    func cancel() {
        let requestID: PHAssetResourceDataRequestID? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            finished = true
            let id = self.requestID
            if let waiter {
                self.waiter = nil
                waiter.resume(throwing: CancellationError())
            }
            return id
        }
        // 回调可能正等待容量令牌；释放足够令牌让它观察取消状态并退出。
        capacity.signal()
        capacity.signal()
        if let requestID { PHAssetResourceManager.default().cancelDataRequest(requestID) }
    }
}

struct FileDownloadEngine: Sendable {
    private let transportFactory: @Sendable () -> any TransferFrameTransport
    private let timeouts: TransferTimeoutConfiguration

    init(
        transportFactory: @escaping @Sendable () -> any TransferFrameTransport = { NWTransferFrameTransport() },
        timeouts: TransferTimeoutConfiguration = .init()
    ) {
        self.transportFactory = transportFactory
        self.timeouts = timeouts
    }

    func download(
        command: DownloadCommand,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TransferProgress) async -> Void = { _ in }
    ) async throws -> DownloadResult {
        guard !command.taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTransferError.invalidTaskId
        }
        guard command.remoteFileId > 0 else { throw FileTransferError.invalidFileId }

        let partURL = destinationURL.appendingPathExtension("part")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partURL.path) {
            guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
                throw FileTransferError.invalidResponse("无法创建下载临时文件")
            }
        }
        var offset = try partURL.fileSize
        if command.expectedFileSize > 0, offset > command.expectedFileSize {
            let resetHandle = try FileHandle(forWritingTo: partURL)
            try resetHandle.truncate(atOffset: 0)
            try resetHandle.close()
            offset = 0
        }

        let handle = try FileHandle(forUpdating: partURL)
        let transport = TimedTransferFrameTransport(base: transportFactory(), timeouts: timeouts)
        var handleClosed = false
        // [修改] 下载取消时关闭 socket，立即解除阻塞中的 receive，并保留 part 文件供续传。
        return try await withTaskCancellationHandler {
            do {
                try handle.seek(toOffset: UInt64(offset))
                try await transport.connect(host: command.configuration.host, port: command.configuration.downloadPort)
                let request = DownloadRequest(
                    fileId: command.remoteFileId,
                    taskId: command.taskId,
                    startOffset: offset,
                    userId: command.identity.userId,
                    userName: command.identity.username,
                    transferToken: command.identity.transferToken
                )
                try await transport.send(Frame(type: .metadata, payload: try ProtocolJSON.encoder().encode(request)))

                let metadataFrame = try await transport.receive()
                guard metadataFrame.type == .acknowledgement || metadataFrame.type == .metadata else {
                    throw FileTransferError.invalidResponse("服务端未返回下载元数据")
                }
                let metadata = try decodeDownloadMetadata(metadataFrame.payload)
                if let responseTaskId = metadata.taskId, responseTaskId != command.taskId {
                    throw FileTransferError.invalidResponse("服务端下载任务 ID 不匹配")
                }
                if let responseFileId = metadata.fileId, responseFileId != command.remoteFileId {
                    // [修改] 串线元数据不能写入当前文件目标。
                    throw FileTransferError.invalidResponse("服务端下载文件 ID 不匹配")
                }
                guard metadata.fileSize >= 0 else {
                    throw FileTransferError.invalidResponse("服务端返回的文件大小无效")
                }
                if metadata.fileSize < offset {
                    guard command.expectedFileSize <= 0 else {
                        throw FileTransferError.invalidResponse("本地断点大于远端文件大小")
                    }
                    // [修改] 首次列表未给文件大小时，旧 part 可能属于已替换的远端文件；拿到真实大小后清零并重连一次。
                    try handle.truncate(atOffset: 0)
                    try handle.close()
                    handleClosed = true
                    await transport.close()
                    return try await download(
                        command: DownloadCommand(
                            configuration: command.configuration,
                            identity: command.identity,
                            taskId: command.taskId,
                            remoteFileId: command.remoteFileId,
                            expectedFileSize: metadata.fileSize
                        ),
                        destinationURL: destinationURL,
                        onProgress: onProgress
                    )
                }
                guard metadata.startOffset == offset else {
                    throw FileTransferError.invalidResponse("服务端下载偏移不一致")
                }

                let ready = TransferReadyRequest(taskId: command.taskId, status: "ready")
                try await transport.send(Frame(type: .acknowledgement, payload: try ProtocolJSON.encoder().encode(ready)))
                await onProgress(TransferProgress(transferredBytes: offset, totalBytes: metadata.fileSize))

                var received = offset
                while true {
                    try Task.checkCancellation()
                    let frame = try await transport.receive()
                    switch frame.type {
                    case .data:
                        try handle.write(contentsOf: frame.payload)
                        received += Int64(frame.payload.count)
                        guard received <= metadata.fileSize else {
                            throw FileTransferError.incompleteTransfer(expected: metadata.fileSize, actual: received)
                        }
                        await onProgress(TransferProgress(transferredBytes: received, totalBytes: metadata.fileSize))
                    case .end:
                        let end = try decodeDownloadEnd(frame.payload)
                        if let responseTaskId = end.taskId, responseTaskId != command.taskId {
                            throw FileTransferError.invalidResponse("服务端下载结束任务 ID 不匹配")
                        }
                        guard end.sentBytes == received - offset,
                              end.endOffset == received,
                              end.fileSize == metadata.fileSize,
                              received == metadata.fileSize else {
                            throw FileTransferError.incompleteTransfer(expected: metadata.fileSize, actual: received)
                        }
                        try handle.synchronize()
                        try handle.close()
                        handleClosed = true
                        // [修改] 目标路径可能在传输期间被用户或文件提供器占用，绝不能删除后覆盖。
                        guard !fileManager.fileExists(atPath: destinationURL.path) else {
                            throw FileTransferError.invalidResponse("目标文件已存在，下载未覆盖")
                        }
                        try fileManager.moveItem(at: partURL, to: destinationURL)
                        await transport.close()
                        await onProgress(TransferProgress(transferredBytes: received, totalBytes: metadata.fileSize))
                        return DownloadResult(downloadedBytes: received, destinationURL: destinationURL)
                    case .acknowledgement, .metadata:
                        let status = try decodeTransferStatus(frame.payload)
                        let normalizedStatus = status.status?.lowercased()
                        if normalizedStatus == "error" || normalizedStatus == "fail" {
                            // [修改] 服务端中途终止下载时立即结束任务并展示真实原因。
                            throw FileTransferError.server(status.message ?? "文件下载失败")
                        }
                    default:
                        continue
                    }
                }
            } catch {
                if !handleClosed { try? handle.close() }
                await transport.close()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }

    private func decodeDownloadMetadata(_ data: Data) throws -> DownloadMetadata {
        let status = try decodeTransferStatus(data)
        guard status.status != "error", status.status != "fail" else {
            throw FileTransferError.server(status.message ?? "文件下载失败")
        }
        return try ProtocolJSON.decoder().decode(DownloadMetadata.self, from: data)
    }

    private func decodeDownloadEnd(_ data: Data) throws -> DownloadEnd {
        let status = try decodeTransferStatus(data)
        guard status.status == nil || status.status == "success" else {
            throw FileTransferError.server(status.message ?? "文件下载失败")
        }
        return try ProtocolJSON.decoder().decode(DownloadEnd.self, from: data)
    }

    private func decodeTransferStatus(_ data: Data) throws -> TransferResponseStatus {
        do {
            return try ProtocolJSON.decoder().decode(TransferResponseStatus.self, from: data)
        } catch {
            throw FileTransferError.invalidResponse("服务端传输响应无法解析")
        }
    }
}

extension FileDownloadEngine: FileDownloading {}

// [修改] 网盘列表缩略图复用服务端 range_pull v2，只拉指定窗口，不把完整原图写入预览缓存。
struct FileRangePullEngine: FileRangePulling, Sendable {
    private let transportFactory: @Sendable () -> any TransferFrameTransport
    private let requestIDFactory: @Sendable () -> String
    private let timeouts: TransferTimeoutConfiguration

    init(
        transportFactory: @escaping @Sendable () -> any TransferFrameTransport = { NWTransferFrameTransport() },
        requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString },
        timeouts: TransferTimeoutConfiguration = .init()
    ) {
        self.transportFactory = transportFactory
        self.requestIDFactory = requestIDFactory
        self.timeouts = timeouts
    }

    func pull(command: RangePullCommand) async throws -> RangePullResult {
        guard !command.taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTransferError.invalidTaskId
        }
        guard command.remoteFileId > 0 else { throw FileTransferError.invalidFileId }
        guard command.startOffset >= 0, command.length > 0 else {
            throw FileTransferError.invalidResponse("文件拉取范围无效")
        }

        let transport = TimedTransferFrameTransport(base: transportFactory(), timeouts: timeouts)
        let requestID = requestIDFactory()
        return try await withTaskCancellationHandler {
            do {
                try await transport.connect(host: command.configuration.host, port: command.configuration.downloadPort)
                let request = RangePullRequest(
                    op: "range_pull",
                    protocolVersion: 2,
                    fileId: command.remoteFileId,
                    taskId: command.taskId,
                    requestId: requestID,
                    startOffset: command.startOffset,
                    length: command.length,
                    userId: command.identity.userId,
                    userName: command.identity.username,
                    transferToken: command.identity.transferToken
                )
                try await transport.send(Frame(type: .metadata, payload: try ProtocolJSON.encoder().encode(request)))

                let acknowledgementFrame = try await transport.receive()
                guard acknowledgementFrame.type == .acknowledgement || acknowledgementFrame.type == .metadata else {
                    throw FileTransferError.invalidResponse("服务端未返回范围拉取确认")
                }
                let acknowledgement = try decodeAcknowledgement(acknowledgementFrame.payload)
                try validate(
                    taskId: acknowledgement.taskId,
                    requestId: acknowledgement.requestId,
                    fileId: acknowledgement.fileId,
                    expectedTaskId: command.taskId,
                    expectedRequestId: requestID,
                    expectedFileId: command.remoteFileId
                )
                guard acknowledgement.fileSize >= 0 else {
                    throw FileTransferError.invalidResponse("服务端返回的范围文件大小无效")
                }
                guard acknowledgement.startOffset == command.startOffset,
                      acknowledgement.startOffset <= acknowledgement.fileSize,
                      acknowledgement.length > 0,
                      acknowledgement.length <= command.length,
                      acknowledgement.length <= acknowledgement.fileSize - acknowledgement.startOffset else {
                    throw FileTransferError.invalidResponse("服务端返回的范围窗口不匹配")
                }

                var data = Data()
                while true {
                    try Task.checkCancellation()
                    let frame = try await transport.receive()
                    switch frame.type {
                    case .data:
                        data.append(frame.payload)
                        guard Int64(data.count) <= acknowledgement.length else {
                            throw FileTransferError.incompleteTransfer(
                                expected: acknowledgement.length,
                                actual: Int64(data.count)
                            )
                        }
                    case .end:
                        let end = try decodeEnd(frame.payload)
                        try validate(
                            taskId: end.taskId,
                            requestId: end.requestId,
                            fileId: nil,
                            expectedTaskId: command.taskId,
                            expectedRequestId: requestID,
                            expectedFileId: command.remoteFileId
                        )
                        let receivedBytes = Int64(data.count)
                        guard end.sentBytes == receivedBytes,
                              end.nextOffset == command.startOffset + receivedBytes,
                              receivedBytes == acknowledgement.length else {
                            throw FileTransferError.incompleteTransfer(
                                expected: acknowledgement.length,
                                actual: receivedBytes
                            )
                        }
                        await transport.close()
                        return RangePullResult(
                            data: data,
                            fileSize: acknowledgement.fileSize,
                            startOffset: command.startOffset,
                            nextOffset: end.nextOffset,
                            isEOF: end.eof || end.nextOffset >= acknowledgement.fileSize
                        )
                    case .acknowledgement, .metadata:
                        _ = try decodeAcknowledgement(frame.payload)
                    default:
                        continue
                    }
                }
            } catch {
                await transport.close()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }

    private func decodeAcknowledgement(_ data: Data) throws -> RangePullAcknowledgement {
        let value: RangePullAcknowledgementEnvelope
        do { value = try ProtocolJSON.decoder().decode(RangePullAcknowledgementEnvelope.self, from: data) }
        catch { throw FileTransferError.invalidResponse("服务端范围拉取确认无法解析") }
        guard value.status.lowercased() != "error", value.status.lowercased() != "fail" else {
            throw FileTransferError.server(value.message ?? "范围拉取失败")
        }
        guard let fileSize = value.fileSize,
              let startOffset = value.startOffset,
              let length = value.length else {
            throw FileTransferError.invalidResponse("服务端范围拉取确认缺少窗口信息")
        }
        return RangePullAcknowledgement(
            taskId: value.taskId,
            requestId: value.requestId,
            fileId: value.fileId,
            fileSize: fileSize,
            startOffset: startOffset,
            length: length
        )
    }

    private func decodeEnd(_ data: Data) throws -> RangePullEnd {
        let value: RangePullEndEnvelope
        do { value = try ProtocolJSON.decoder().decode(RangePullEndEnvelope.self, from: data) }
        catch { throw FileTransferError.invalidResponse("服务端范围拉取结束帧无法解析") }
        guard value.status.lowercased() == "success" else {
            throw FileTransferError.server(value.message ?? "范围拉取失败")
        }
        guard let sentBytes = value.sentBytes,
              let nextOffset = value.nextOffset,
              let eof = value.eof else {
            throw FileTransferError.invalidResponse("服务端范围拉取结束帧缺少进度信息")
        }
        return RangePullEnd(
            taskId: value.taskId,
            requestId: value.requestId,
            sentBytes: sentBytes,
            nextOffset: nextOffset,
            eof: eof
        )
    }

    private func validate(
        taskId: String?,
        requestId: String?,
        fileId: Int64?,
        expectedTaskId: String,
        expectedRequestId: String,
        expectedFileId: Int64
    ) throws {
        if let taskId, taskId != expectedTaskId {
            throw FileTransferError.invalidResponse("服务端范围拉取任务 ID 不匹配")
        }
        if let requestId, requestId != expectedRequestId {
            throw FileTransferError.invalidResponse("服务端范围拉取请求 ID 不匹配")
        }
        if let fileId, fileId != expectedFileId {
            throw FileTransferError.invalidResponse("服务端范围拉取文件 ID 不匹配")
        }
    }
}

private struct UploadResumeRequest: Encodable {
    let fileSize: Int64
    let dirId: Int64
    let fileName: String
    let userId: Int64
    let userName: String
    let taskId: String
    let md5: String
    let startOffset: Int64
    let transferToken: String
    let uploadPurpose: String
    let connectionReuse: Bool
    let batchId: String?
}

private struct UploadMetadataRequest: Encodable {
    let md5: String
    let fileName: String
    let fileSize: Int64
    let fileType: String
    let dirId: Int64
    let userId: Int64
    let userName: String
    let taskId: String
    let transferToken: String
    let uploadPurpose: String
    let connectionReuse: Bool
    let batchId: String?
}

private struct UploadEndRequest: Encodable { let taskId: String }

private struct DownloadRequest: Encodable {
    let fileId: Int64
    let taskId: String
    let startOffset: Int64
    let userId: Int64
    let userName: String
    let transferToken: String
}

private struct RangePullRequest: Encodable {
    let op: String
    let protocolVersion: Int
    let fileId: Int64
    let taskId: String
    let requestId: String
    let startOffset: Int64
    let length: Int64
    let userId: Int64
    let userName: String
    let transferToken: String
}

private struct TransferReadyRequest: Encodable {
    let taskId: String
    let status: String
}

private struct TransferAcknowledgement: Decodable {
    let status: String
    let taskId: String?
    let uploadedSize: Int64?
    let fileId: Int64?
    let message: String?
}

private struct TransferResponseStatus: Decodable {
    let status: String?
    let message: String?
}

private struct DownloadMetadata: Decodable {
    let fileId: Int64?
    let fileSize: Int64
    let taskId: String?
    let startOffset: Int64
}

private struct DownloadEnd: Decodable {
    let taskId: String?
    let sentBytes: Int64
    let endOffset: Int64
    let fileSize: Int64
}

// [修改] 失败 ACK/END 是短帧，先用可选字段解码状态，再校验成功帧的必需字段。
private struct RangePullAcknowledgementEnvelope: Decodable {
    let status: String
    let taskId: String?
    let requestId: String?
    let fileId: Int64?
    let fileSize: Int64?
    let startOffset: Int64?
    let length: Int64?
    let eof: Bool?
    let message: String?
}

private struct RangePullAcknowledgement {
    let taskId: String?
    let requestId: String?
    let fileId: Int64?
    let fileSize: Int64
    let startOffset: Int64
    let length: Int64
}

private struct RangePullEndEnvelope: Decodable {
    let status: String
    let taskId: String?
    let requestId: String?
    let sentBytes: Int64?
    let nextOffset: Int64?
    let eof: Bool?
    let message: String?
}

private struct RangePullEnd {
    let taskId: String?
    let requestId: String?
    let sentBytes: Int64
    let nextOffset: Int64
    let eof: Bool
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension URL {
    var fileSize: Int64 {
        get throws {
            let values = try resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        }
    }
}
