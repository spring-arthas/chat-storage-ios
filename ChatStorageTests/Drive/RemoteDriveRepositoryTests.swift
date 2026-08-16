import XCTest
@testable import ChatStorage

final class RemoteDriveRepositoryTests: XCTestCase {
    // [修改] 服务端失败响应缺少消息时，UI 仍要显示可理解的网盘错误。
    func testBlankServerErrorUsesDriveFallbackMessage() {
        XCTAssertEqual(DriveRepositoryError.server("   ").errorDescription, "网盘操作失败")
    }

    func testRootsDecodesRecursiveDirectoryTreeAndMetadata() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":1,"pId":-1,"fileName":"我的网盘","filePath":"/alice","isFile":"N","hasChild":"Y","gmtCreated":100,"gmtModified":200,"childFileList":[{"id":2,"pId":1,"fileName":"照片","isFile":"N","hasChild":"Y","childFileList":[{"id":3,"pId":2,"fileName":"旅行","isFile":"N","hasChild":"N","childFileList":[]}]}]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let roots = try await repository.roots()
        let root = try XCTUnwrap(roots.first)

        // [修改] 0x15 返回的是递归目录树，iOS 必须保留每一级 childFileList。
        XCTAssertEqual(root.children.first?.children.first?.name, "旅行")
        XCTAssertEqual(root.path, "/alice")
        XCTAssertEqual(root.createdAt, 100)
        XCTAssertEqual(root.modifiedAt, 200)
    }

    // [修改] 不同服务端版本会把根目录 data 返回为对象或数组，两种结构都必须兼容。
    func testRootsAcceptsArrayPayload() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":[{"id":1,"pId":-1,"fileName":"我的网盘","isFile":"N"},{"id":9,"pId":-1,"fileName":"共享盘","isFile":"N"}]}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let roots = try await repository.roots()

        XCTAssertEqual(roots.map(\.id), [1, 9])
    }

    // [修改] 展开目录时使用 0x15 携带 dirId，并兼容服务端返回父节点包装 childFileList。
    func testDirectoryChildrenRequestsDirectoryIDAndUnwrapsParentNode() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":2,"pId":1,"fileName":"照片","isFile":"N","hasChild":"Y","childFileList":[{"id":3,"pId":2,"fileName":"旅行","isFile":"N","hasChild":"N"}]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let children = try await repository.directoryChildren(id: 2)

        XCTAssertEqual(children.map(\.id), [3])
        let frames = await client.sentFrames
        XCTAssertEqual(frames.first?.type, .directoryListRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(object["dirId"] as? Int, 2)
    }

    // [修改] 当前 net-server 的 0x15 会忽略 dirId 并返回完整根树，懒加载必须递归找到目标节点。
    func testDirectoryChildrenExtractsNestedParentFromFullRootTree() async throws {
        let payload = Data(#"{"success":true,"data":{"id":1,"pId":-1,"fileName":"我的网盘","isFile":"N","childFileList":[{"id":2,"pId":1,"fileName":"照片","isFile":"N","childFileList":[{"id":3,"pId":2,"fileName":"旅行","isFile":"N","childFileList":[]}]},{"id":8,"pId":1,"fileName":"文档","isFile":"N","childFileList":[]}]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let children = try await repository.directoryChildren(id: 2)

        XCTAssertEqual(children.map(\.id), [3])
    }

    // [修改] 服务端返回了与请求目录无关的完整树时，不能把根节点错误挂到目标目录下面。
    func testDirectoryChildrenRejectsUnrelatedTree() async {
        let payload = Data(#"{"success":true,"data":{"id":1,"pId":-1,"fileName":"我的网盘","isFile":"N","childFileList":[]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        do {
            _ = try await repository.directoryChildren(id: 99)
            XCTFail("无关目录树不应成为请求目录的子节点")
        } catch let error as DriveRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("应映射为 DriveRepositoryError，实际为 \(error)")
        }
    }

    // [修改] 完整递归响应已经明确给出空 childFileList 时，以实际列表为准，忽略数据库残留 hasChild=Y。
    func testExplicitEmptyChildListOverridesStaleHasChildFlag() async throws {
        let payload = Data(#"{"success":true,"data":{"id":1,"pId":-1,"fileName":"我的网盘","isFile":"N","hasChild":"Y","childFileList":[]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let roots = try await repository.roots()
        let root = try XCTUnwrap(roots.first)

        XCTAssertFalse(root.hasChildren)
    }

    // [修改] 与 macOS 协议实现一致：目录请求成功但 data 为 null 时表示空结果，不应当作加载失败。
    func testSuccessfulNullDirectoryPayloadReturnsEmptyCollections() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":null}"#.utf8)
        let client = DriveFrameClient(responses: [
            Frame(type: .directoryResponse, payload: payload),
            Frame(type: .directoryResponse, payload: payload),
        ])
        let repository = RemoteDriveRepository(client: client)

        let roots = try await repository.roots()
        let children = try await repository.directoryChildren(id: 2)

        XCTAssertTrue(roots.isEmpty)
        XCTAssertTrue(children.isEmpty)
    }

    // [修改] 缺少有效 ID 的目录不能进入树，否则后续选择、重命名和删除会指向错误对象。
    func testRootsRejectDirectoryWithoutValidIdentifier() async {
        let payload = Data(#"{"success":true,"data":{"pId":-1,"fileName":"坏目录","isFile":"N"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        do {
            _ = try await repository.roots()
            XCTFail("无效目录 ID 不应解码成功")
        } catch let error as DriveRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("应映射为 DriveRepositoryError，实际为 \(error)")
        }
    }

    func testListFilesUsesFileListFrameAndDecodesPage() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"recordList":[{"id":4,"pId":1,"parentDirName":"文档","fileName":"报告.pdf","filePath":"/alice/文档/报告.pdf","fileSize":128,"isFile":"Y","fileType":"pdf","gmtCreated":100,"gmtModified":200,"md5":"abc"}],"currentPage":2,"pageSize":20,"totalCount":41,"totalPage":3}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let page = try await repository.listFiles(directoryId: 1, page: 2, pageSize: 20, search: "报告")

        XCTAssertEqual(page.records.first?.name, "报告.pdf")
        XCTAssertTrue(page.records.first?.isFile == true)
        XCTAssertEqual(page.records.first?.parentDirectoryName, "文档")
        XCTAssertEqual(page.records.first?.md5, "abc")
        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.totalPages, 3)
        let frames = await client.sentFrames
        let sent = try XCTUnwrap(frames.first)
        XCTAssertEqual(sent.type, .fileListRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        XCTAssertEqual(object["dirId"] as? Int, 1)
        XCTAssertEqual(object["fileName"] as? String, "报告")
        XCTAssertEqual(object["pageNum"] as? Int, 2)
    }

    // [修改] macOS 同协议已兼容数字字符串，iOS 也必须接受服务端的混合数字类型。
    func testListFilesDecodesNumericFieldsReturnedAsStrings() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"recordList":[{"id":"4","pId":"1","fileName":"报告.pdf","fileSize":"128","isFile":"Y","gmtCreated":"100"}],"currentPage":"2","pageSize":"20","totalCount":"41","totalPage":"3"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let page = try await repository.listFiles(directoryId: 1, page: 2, pageSize: 20, search: "")
        let file = try XCTUnwrap(page.records.first)

        XCTAssertEqual(file.id, 4)
        XCTAssertEqual(file.parentId, 1)
        XCTAssertEqual(file.size, 128)
        XCTAssertEqual(file.createdAt, 100)
        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.pageSize, 20)
        XCTAssertEqual(page.totalCount, 41)
        XCTAssertEqual(page.totalPages, 3)
    }

    // [修改] 空目录在部分 net-server 版本会返回成功加 data:null，必须生成当前请求对应的空分页。
    func testSuccessfulNullFileListPayloadReturnsEmptyRequestedPage() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":null}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let page = try await repository.listFiles(directoryId: 9, page: 3, pageSize: 20, search: "")

        XCTAssertTrue(page.records.isEmpty)
        XCTAssertEqual(page.currentPage, 3)
        XCTAssertEqual(page.pageSize, 20)
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertEqual(page.totalPages, 0)
    }

    // [修改] 协议数据损坏时统一映射为网盘业务错误，页面不能收到 JSONDecoder 的内部异常。
    func testMalformedListResponseMapsToInvalidResponse() async {
        let payload = Data(#"{"success":true,"code":200,"data":{"recordList":[{"id":"not-a-number","fileName":"坏数据"}]}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        do {
            _ = try await repository.listFiles(directoryId: 1, page: 1, pageSize: 20, search: "")
            XCTFail("畸形网盘响应不应解码成功")
        } catch let error as DriveRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("应映射为 DriveRepositoryError，实际为 \(error)")
        }
    }

    // [修改] 文件列表中缺少 ID 的记录必须整页拒绝，不能生成可操作的 fileId=0 行。
    func testListFilesRejectsRecordWithoutValidIdentifier() async {
        let payload = Data(#"{"success":true,"data":{"recordList":[{"fileName":"坏数据.pdf","isFile":"Y"}],"currentPage":1,"pageSize":20,"totalCount":1}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        do {
            _ = try await repository.listFiles(directoryId: 1, page: 1, pageSize: 20, search: "")
            XCTFail("无效文件 ID 不应进入列表")
        } catch let error as DriveRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("应映射为 DriveRepositoryError，实际为 \(error)")
        }
    }

    func testCreateDirectoryUsesExistingDirectoryProtocol() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":2,"pId":1,"fileName":"照片","isFile":"N","hasChild":"N"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        try await repository.createDirectory(parentId: 1, name: "照片")

        let frames = await client.sentFrames
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(frames[0].type, .directoryCreateRequest)
        XCTAssertEqual(object["pId"] as? Int, 1)
        XCTAssertEqual(object["dirName"] as? String, "照片")
    }

    func testRenameAndDeleteDirectoryAcceptObjectAndNullResponses() async throws {
        let renamePayload = Data(#"{"success":true,"code":200,"data":{"id":2,"pId":1,"fileName":"相册","isFile":"N"}}"#.utf8)
        let deletePayload = Data(#"{"success":true,"code":200,"data":null}"#.utf8)
        let client = DriveFrameClient(responses: [
            Frame(type: .directoryResponse, payload: renamePayload),
            Frame(type: .directoryResponse, payload: deletePayload),
        ])
        let repository = RemoteDriveRepository(client: client)

        try await repository.renameDirectory(id: 2, name: "相册")
        try await repository.deleteDirectory(id: 2)

        let frames = await client.sentFrames
        XCTAssertEqual(frames.map(\.type), [.directoryUpdateRequest, .directoryDeleteRequest])
    }

    func testMoveDirectoryUsesDirectoryMoveProtocol() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":4,"pId":8,"fileName":"旅行","isFile":"N"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .directoryResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        try await repository.moveDirectory(id: 4, targetParentId: 8)

        let frames = await client.sentFrames
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(frames[0].type, .directoryMoveRequest)
        XCTAssertEqual(object["dirId"] as? Int, 4)
        XCTAssertEqual(object["targetParentId"] as? Int, 8)
    }

    func testFileDetailUsesDetailProtocolAndDecodesMetadata() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":4,"pId":1,"parentDirName":"文档","fileName":"报告.pdf","filePath":"/alice/文档/报告.pdf","fileSize":128,"isFile":"Y","fileType":"pdf","gmtCreated":100,"gmtModified":200,"md5":"abc"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        let detail = try await repository.fileDetail(id: 4)

        XCTAssertEqual(detail.parentDirectoryName, "文档")
        XCTAssertEqual(detail.path, "/alice/文档/报告.pdf")
        XCTAssertEqual(detail.md5, "abc")
        let frames = await client.sentFrames
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(frames[0].type, .fileDetailRequest)
        XCTAssertEqual(object["fileId"] as? Int, 4)
    }

    // [修改] 详情响应必须对应请求文件，防止并发或服务端串包展示另一文件的数据。
    func testFileDetailRejectsMismatchedIdentifier() async {
        let payload = Data(#"{"success":true,"data":{"id":9,"pId":1,"fileName":"其他文件.pdf","isFile":"Y"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        do {
            _ = try await repository.fileDetail(id: 4)
            XCTFail("详情响应 ID 与请求不一致时不应成功")
        } catch let error as DriveRepositoryError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("应映射为 DriveRepositoryError，实际为 \(error)")
        }
    }

    func testRenameFileUsesFileRenameProtocol() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":{"id":4,"pId":1,"fileName":"新报告.pdf","isFile":"Y","fileType":"pdf"}}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        try await repository.renameFile(id: 4, name: "新报告.pdf")

        let frames = await client.sentFrames
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(frames[0].type, .fileRenameRequest)
        XCTAssertEqual(object["fileId"] as? Int, 4)
        XCTAssertEqual(object["newFileName"] as? String, "新报告.pdf")
    }

    func testDeleteFileUsesFileDeleteProtocol() async throws {
        let payload = Data(#"{"success":true,"code":200,"data":null}"#.utf8)
        let client = DriveFrameClient(responses: [Frame(type: .fileResponse, payload: payload)])
        let repository = RemoteDriveRepository(client: client)

        try await repository.deleteFile(id: 4)

        let frames = await client.sentFrames
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0].payload) as? [String: Any])
        XCTAssertEqual(frames[0].type, .fileDeleteRequest)
        XCTAssertEqual(object["fileId"] as? Int, 4)
    }
}

private actor DriveFrameClient: FrameRequesting {
    private var responses: [Frame]
    private(set) var sentFrames: [Frame] = []
    init(responses: [Frame]) { self.responses = responses }
    func connect() async throws {}
    func request(_ frame: Frame, expecting: Set<FrameType>, timeout: Duration) async throws -> Frame {
        sentFrames.append(frame)
        return responses.removeFirst()
    }
}
