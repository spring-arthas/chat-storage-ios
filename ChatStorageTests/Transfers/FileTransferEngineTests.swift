import XCTest
@testable import ChatStorage

final class FileTransferEngineTests: XCTestCase {
    // [修改] 服务端没有提供错误文案时，传输界面不能显示空白错误。
    func testBlankTransferErrorUsesFallbackMessage() {
        XCTAssertEqual(FileTransferError.server("   ").errorDescription, "文件传输失败")
        XCTAssertEqual(FileTransferError.invalidResponse("\n").errorDescription, "文件传输失败")
    }

    func testRangePullRequestsOnlyRequestedPrefixAndReturnsWindow() async throws {
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"status":"ok","taskId":"thumbnail-1","requestId":"request-1","fileId":77,"fileSize":50000000,"startOffset":0,"length":4,"eof":false}"#),
            Frame(type: .data, payload: Data("abcd".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"thumbnail-1","requestId":"request-1","sentBytes":4,"nextOffset":4,"eof":false}"#)
        ])
        let engine = FileRangePullEngine(
            transportFactory: { transport },
            requestIDFactory: { "request-1" }
        )

        let result = try await engine.pull(
            command: RangePullCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "thumbnail-1",
                remoteFileId: 77,
                startOffset: 0,
                length: 4
            )
        )

        XCTAssertEqual(result.data, Data("abcd".utf8))
        XCTAssertEqual(result.fileSize, 50_000_000)
        XCTAssertEqual(result.nextOffset, 4)
        XCTAssertFalse(result.isEOF)
        let frames = await transport.sentFrames
        XCTAssertEqual(frames.map(\.type), [.metadata])
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(request["op"] as? String, "range_pull")
        XCTAssertEqual(request["protocolVersion"] as? Int, 2)
        XCTAssertEqual(request["length"] as? Int, 4)
        XCTAssertEqual(request["startOffset"] as? Int, 0)
    }

    // [修改] 服务端失败 ACK 不带成功帧字段时，仍要把真实错误信息透传给界面。
    func testRangePullSurfacesServerErrorFromShortAcknowledgement() async throws {
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"status":"error","taskId":"thumbnail-1","requestId":"request-1","code":40410,"message":"file not found"}"#)
        ])
        let engine = FileRangePullEngine(
            transportFactory: { transport },
            requestIDFactory: { "request-1" }
        )

        do {
            _ = try await engine.pull(
                command: RangePullCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "thumbnail-1",
                    remoteFileId: 77,
                    startOffset: 0,
                    length: 4
                )
            )
            XCTFail("失败 ACK 不应被当作成功响应")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .server("file not found"))
        }
    }

    // [修改] 传输中途返回的失败 END 同样只有错误字段，不能丢失服务端原因。
    func testRangePullSurfacesServerErrorFromShortEndFrame() async throws {
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"status":"ok","taskId":"thumbnail-1","requestId":"request-1","fileId":77,"fileSize":50000000,"startOffset":0,"length":4,"eof":false}"#),
            Frame(type: .data, payload: Data("ab".utf8)),
            jsonFrame(.end, #"{"status":"error","taskId":"thumbnail-1","requestId":"request-1","code":50031,"message":"io read failed"}"#)
        ])
        let engine = FileRangePullEngine(
            transportFactory: { transport },
            requestIDFactory: { "request-1" }
        )

        do {
            _ = try await engine.pull(
                command: RangePullCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "thumbnail-1",
                    remoteFileId: 77,
                    startOffset: 0,
                    length: 4
                )
            )
            XCTFail("失败 END 不应被当作成功响应")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .server("io read failed"))
        }
    }

    func testUploadPerformsResumeMetadataDataAndEndHandshake() async throws {
        let bytes = Data("abcdefghij".utf8)
        let sourceURL = try temporaryFile(named: "note.txt", data: bytes)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.resumeAcknowledgement, #"{"status":"new","taskId":"upload-1","uploadedSize":0}"#),
            jsonFrame(.acknowledgement, #"{"status":"ready","taskId":"upload-1","uploadedSize":0}"#),
            jsonFrame(.acknowledgement, #"{"status":"progress","taskId":"upload-1","uploadedSize":10}"#),
            jsonFrame(.acknowledgement, #"{"status":"success","taskId":"upload-1","fileId":901}"#)
        ])
        let engine = FileUploadEngine(transportFactory: { transport })

        let result = try await engine.upload(
            command: UploadCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "upload-1",
                targetDirectoryId: 12
            ),
            sourceURL: sourceURL
        )

        XCTAssertEqual(result.fileId, 901)
        XCTAssertEqual(result.uploadedBytes, 10)
        let frames = await transport.sentFrames
        XCTAssertEqual(frames.map(\.type), [.resumeCheck, .metadata, .data, .end])
        XCTAssertEqual(frames[2].flags & Frame.transferHasOffsetFlag, Frame.transferHasOffsetFlag)
        XCTAssertEqual(frames[2].flags & Frame.transferNeedsAcknowledgementFlag, Frame.transferNeedsAcknowledgementFlag)
        XCTAssertEqual(frames[2].payload.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }, 0)
        XCTAssertEqual(Data(frames[2].payload.dropFirst(8)), bytes)
    }

    // [修改] END 后的完整性校验允许超过普通空闲窗口，避免大文件已成功却被客户端判超时。
    func testUploadAllowsDelayedFinalAcknowledgementBeyondIdleTimeout() async throws {
        let bytes = Data("abcdefghij".utf8)
        let sourceURL = try temporaryFile(named: "delayed-final-ack.txt", data: bytes)
        let transport = DelayedFinalAcknowledgementTransport(
            responses: [
                jsonFrame(.resumeAcknowledgement, #"{"status":"new","taskId":"upload-delayed-final","uploadedSize":0}"#),
                jsonFrame(.acknowledgement, #"{"status":"ready","taskId":"upload-delayed-final","uploadedSize":0}"#),
                jsonFrame(.acknowledgement, #"{"status":"progress","taskId":"upload-delayed-final","uploadedSize":10}"#),
                jsonFrame(.acknowledgement, #"{"status":"success","taskId":"upload-delayed-final","fileId":902}"#)
            ],
            finalDelay: .milliseconds(100)
        )
        let engine = FileUploadEngine(
            transportFactory: { transport },
            timeouts: TransferTimeoutConfiguration(connect: .seconds(1), idle: .milliseconds(50))
        )

        let result = try await engine.upload(
            command: UploadCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "upload-delayed-final",
                targetDirectoryId: 12
            ),
            sourceURL: sourceURL
        )

        XCTAssertEqual(result.fileId, 902)
        XCTAssertEqual(result.uploadedBytes, 10)
    }

    func testDownloadResumesFromPartialFileAndCommitsAfterValidEndFrame() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let partURL = destinationURL.appendingPathExtension("part")
        try Data("abc".utf8).write(to: partURL)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":10,"taskId":"download-1","startOffset":3}"#),
            Frame(type: .data, payload: Data("defg".utf8)),
            Frame(type: .data, payload: Data("hij".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"download-1","sentBytes":7,"endOffset":10,"fileSize":10}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        let result = try await engine.download(
            command: DownloadCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "download-1",
                remoteFileId: 77,
                expectedFileSize: 10
            ),
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.downloadedBytes, 10)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("abcdefghij".utf8))
        let frames = await transport.sentFrames
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(request["startOffset"] as? Int, 3)
        XCTAssertEqual(frames[1].type, .acknowledgement)
    }

    // [修改] 下载期间新出现的同名文件属于用户数据，完成提交不能先删除再覆盖。
    func testDownloadDoesNotOverwriteDestinationCreatedDuringTransfer() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let partURL = destinationURL.appendingPathExtension("part")
        let userData = Data("user-created".utf8)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":3,"taskId":"download-collision","startOffset":0}"#),
            Frame(type: .data, payload: Data("abc".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"download-collision","sentBytes":3,"endOffset":3,"fileSize":3}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        do {
            _ = try await engine.download(
                command: DownloadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "download-collision",
                    remoteFileId: 77,
                    expectedFileSize: 3
                ),
                destinationURL: destinationURL,
                onProgress: { progress in
                    guard progress.transferredBytes == 3,
                          !FileManager.default.fileExists(atPath: destinationURL.path) else { return }
                    try? userData.write(to: destinationURL, options: .atomic)
                }
            )
            XCTFail("传输期间出现的同名文件不应被覆盖")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .invalidResponse("目标文件已存在，下载未覆盖"))
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), userData)
        XCTAssertEqual(try Data(contentsOf: partURL), Data("abc".utf8))
    }

    // [修改] 下载元数据属于其他远端文件时必须拒绝，不能把串线内容写到当前目标路径。
    func testDownloadRejectsMetadataForAnotherRemoteFile() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":88,"fileName":"wrong.txt","fileSize":3,"taskId":"download-file-id","startOffset":0}"#),
            Frame(type: .data, payload: Data("bad".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"download-file-id","sentBytes":3,"endOffset":3,"fileSize":3}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        do {
            _ = try await engine.download(
                command: DownloadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "download-file-id",
                    remoteFileId: 77,
                    expectedFileSize: 3
                ),
                destinationURL: destinationURL
            )
            XCTFail("其他远端文件的元数据不应被接受")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .invalidResponse("服务端下载文件 ID 不匹配"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // [修改] 结束帧属于其他任务时不能提交 part 文件。
    func testDownloadRejectsEndFrameForAnotherTask() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":3,"taskId":"download-end-id","startOffset":0}"#),
            Frame(type: .data, payload: Data("abc".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"another-task","sentBytes":3,"endOffset":3,"fileSize":3}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        do {
            _ = try await engine.download(
                command: DownloadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "download-end-id",
                    remoteFileId: 77,
                    expectedFileSize: 3
                ),
                destinationURL: destinationURL
            )
            XCTFail("其他任务的结束帧不应提交文件")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .invalidResponse("服务端下载结束任务 ID 不匹配"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // [修改] 下载过程中服务端主动返回失败 ACK 时必须立即透传，不能忽略后一直等到超时。
    func testDownloadSurfacesMidstreamServerErrorAcknowledgement() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":3,"taskId":"download-error","startOffset":0}"#),
            jsonFrame(.acknowledgement, #"{"status":"error","taskId":"download-error","message":"磁盘读取失败"}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        do {
            _ = try await engine.download(
                command: DownloadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "download-error",
                    remoteFileId: 77,
                    expectedFileSize: 3
                ),
                destinationURL: destinationURL
            )
            XCTFail("服务端失败 ACK 不应被忽略")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .server("磁盘读取失败"))
        }
    }

    // [修改] 范围拉取确认中的负文件大小属于损坏响应，不能进入缩略图渲染。
    func testRangePullRejectsNegativeRemoteFileSize() async throws {
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"status":"ok","taskId":"thumbnail-negative","requestId":"request-negative","fileId":77,"fileSize":-1,"startOffset":0,"length":1}"#)
        ])
        let engine = FileRangePullEngine(
            transportFactory: { transport },
            requestIDFactory: { "request-negative" }
        )

        do {
            _ = try await engine.pull(
                command: RangePullCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "thumbnail-negative",
                    remoteFileId: 77,
                    startOffset: 0,
                    length: 1
                )
            )
            XCTFail("负文件大小不应被接受")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .invalidResponse("服务端返回的范围文件大小无效"))
        }
    }

    // [修改] 服务端确认的范围不能越过文件末尾，否则缩略图可能接收其他协议数据。
    func testRangePullRejectsWindowBeyondRemoteFileSize() async throws {
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"status":"ok","taskId":"thumbnail-overflow","requestId":"request-overflow","fileId":77,"fileSize":4,"startOffset":3,"length":2}"#)
        ])
        let engine = FileRangePullEngine(
            transportFactory: { transport },
            requestIDFactory: { "request-overflow" }
        )

        do {
            _ = try await engine.pull(
                command: RangePullCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "thumbnail-overflow",
                    remoteFileId: 77,
                    startOffset: 3,
                    length: 2
                )
            )
            XCTFail("越过远端文件末尾的范围不应被接受")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .invalidResponse("服务端返回的范围窗口不匹配"))
        }
    }

    // [修改] 文件大小未知时不能把已有 part 当成超长文件清空，拿到元数据后继续断点。
    func testDownloadWithUnknownExpectedSizePreservesPartialFile() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let partURL = destinationURL.appendingPathExtension("part")
        try Data("abc".utf8).write(to: partURL)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":5,"taskId":"download-unknown","startOffset":3}"#),
            Frame(type: .data, payload: Data("de".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"download-unknown","sentBytes":2,"endOffset":5,"fileSize":5}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        let result = try await engine.download(
            command: DownloadCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "download-unknown",
                remoteFileId: 77,
                expectedFileSize: 0
            ),
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.downloadedBytes, 5)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("abcde".utf8))
        let frames = await transport.sentFrames
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(request["startOffset"] as? Int, 3)
    }

    // [修改] 未知大小任务拿到真实元数据后，过长旧断点必须清空并只重试一次，不能永久失败。
    func testDownloadWithUnknownExpectedSizeRestartsWhenPartialFileExceedsRemoteSize() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let partURL = destinationURL.appendingPathExtension("part")
        try Data("stale-data".utf8).write(to: partURL)
        let transport = ScriptedTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":5,"taskId":"download-reset","startOffset":10}"#),
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":5,"taskId":"download-reset","startOffset":0}"#),
            Frame(type: .data, payload: Data("abcde".utf8)),
            jsonFrame(.end, #"{"status":"success","taskId":"download-reset","sentBytes":5,"endOffset":5,"fileSize":5}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })

        let result = try await engine.download(
            command: DownloadCommand(
                configuration: try ServerConfiguration(host: "127.0.0.1"),
                identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                taskId: "download-reset",
                remoteFileId: 77,
                expectedFileSize: 0
            ),
            destinationURL: destinationURL
        )

        XCTAssertEqual(result.downloadedBytes, 5)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("abcde".utf8))
        let frames = await transport.sentFrames
        XCTAssertEqual(frames.map(\.type), [.metadata, .metadata, .acknowledgement])
        let firstRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        let secondRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[1].payload) as? [String: Any])
        XCTAssertEqual(firstRequest["startOffset"] as? Int, 10)
        XCTAssertEqual(secondRequest["startOffset"] as? Int, 0)
    }

    // [修改] 服务端超过空闲窗口没有回帧时必须关闭连接并返回明确超时。
    func testUploadIdleTimeoutClosesTransport() async throws {
        let sourceURL = try temporaryFile(named: "timeout.txt", data: Data("wait".utf8))
        let transport = BlockingTransferTransport()
        let engine = FileUploadEngine(
            transportFactory: { transport },
            timeouts: TransferTimeoutConfiguration(connect: .seconds(1), idle: .milliseconds(50))
        )

        do {
            _ = try await engine.upload(
                command: UploadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "upload-timeout",
                    targetDirectoryId: 12,
                    knownMD5: "098f6bcd4621d373cade4e832627b4f6"
                ),
                sourceURL: sourceURL
            )
            XCTFail("空闲超时后不应继续等待")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .timedOut("等待服务器响应"))
        }
        let isClosed = await transport.isClosed
        XCTAssertTrue(isClosed)
    }

    func testUploadCancellationClosesTransportWhileWaitingForAcknowledgement() async throws {
        let sourceURL = try temporaryFile(named: "waiting.txt", data: Data("wait".utf8))
        let transport = BlockingTransferTransport()
        let engine = FileUploadEngine(transportFactory: { transport })
        let task = Task {
            try await engine.upload(
                command: UploadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "upload-cancel",
                    targetDirectoryId: 12,
                    knownMD5: "098f6bcd4621d373cade4e832627b4f6"
                ),
                sourceURL: sourceURL
            )
        }

        await transport.waitUntilReceiving()
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        // [修改] 暂停必须主动关闭正在等待 ACK 的连接，而不是等服务端先返回。
        let closedByCancellation = await transport.isClosed
        if !closedByCancellation { await transport.close() }
        let result = await task.result

        XCTAssertTrue(closedByCancellation)
        guard case .failure(let error) = result else {
            return XCTFail("取消上传后不应成功")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testDownloadCancellationClosesTransportWhileWaitingForData() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = BlockingTransferTransport(responses: [
            jsonFrame(.acknowledgement, #"{"fileId":77,"fileName":"remote.txt","fileSize":4,"taskId":"download-cancel","startOffset":0}"#)
        ])
        let engine = FileDownloadEngine(transportFactory: { transport })
        let task = Task {
            try await engine.download(
                command: DownloadCommand(
                    configuration: try ServerConfiguration(host: "127.0.0.1"),
                    identity: .init(userId: 7, username: "alice", transferToken: "transfer-token"),
                    taskId: "download-cancel",
                    remoteFileId: 77,
                    expectedFileSize: 4
                ),
                destinationURL: destinationURL
            )
        }

        await transport.waitUntilReceiveCount(2)
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        // [修改] 下载暂停同样必须解除等待数据的 socket receive。
        let closedByCancellation = await transport.isClosed
        if !closedByCancellation { await transport.close() }
        let result = await task.result

        XCTAssertTrue(closedByCancellation)
        guard case .failure(let error) = result else {
            return XCTFail("取消下载后不应成功")
        }
        XCTAssertTrue(error is CancellationError)
    }

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

private actor ScriptedTransferTransport: TransferFrameTransport {
    private var responses: [Frame]
    private(set) var sentFrames: [Frame] = []

    init(responses: [Frame]) {
        self.responses = responses
    }

    func connect(host: String, port: Int) async throws {}
    func send(_ frame: Frame) async throws { sentFrames.append(frame) }
    func receive() async throws -> Frame { responses.removeFirst() }
    func close() async {}
}

// [修改] 仅延迟第四次 receive，精确模拟服务端 END 后重新计算整文件 MD5。
private actor DelayedFinalAcknowledgementTransport: TransferFrameTransport {
    private var responses: [Frame]
    private let finalDelay: Duration

    init(responses: [Frame], finalDelay: Duration) {
        self.responses = responses
        self.finalDelay = finalDelay
    }

    func connect(host: String, port: Int) async throws {}
    func send(_ frame: Frame) async throws {}

    func receive() async throws -> Frame {
        if responses.count == 1 {
            try await Task.sleep(for: finalDelay)
        }
        return responses.removeFirst()
    }

    func close() async {}
}

private actor BlockingTransferTransport: TransferFrameTransport {
    private var responses: [Frame]
    private var receiveContinuation: CheckedContinuation<Frame, Error>?
    private var receiveWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var isClosed = false
    private var receiveCount = 0

    init(responses: [Frame] = []) {
        self.responses = responses
    }

    func connect(host: String, port: Int) async throws {}
    func send(_ frame: Frame) async throws {}

    func receive() async throws -> Frame {
        receiveCount += 1
        let readyWaiters = receiveWaiters.filter { $0.count <= receiveCount }
        receiveWaiters.removeAll { $0.count <= receiveCount }
        readyWaiters.forEach { $0.continuation.resume() }
        if !responses.isEmpty { return responses.removeFirst() }
        return try await withCheckedThrowingContinuation { receiveContinuation = $0 }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    func waitUntilReceiving() async {
        await waitUntilReceiveCount(1)
    }

    func waitUntilReceiveCount(_ expectedCount: Int) async {
        guard receiveCount < expectedCount else { return }
        await withCheckedContinuation { receiveWaiters.append((expectedCount, $0)) }
    }
}

private func jsonFrame(_ type: FrameType, _ json: String) -> Frame {
    Frame(type: type, payload: Data(json.utf8))
}
