import Foundation

protocol DriveRepository: Sendable {
    func roots() async throws -> [DriveFileEntry]
    func directoryChildren(id: Int64) async throws -> [DriveFileEntry]
    func listFiles(directoryId: Int64, page: Int, pageSize: Int, search: String) async throws -> DrivePage
    func createDirectory(parentId: Int64, name: String) async throws
    func renameDirectory(id: Int64, name: String) async throws
    func deleteDirectory(id: Int64) async throws
    func moveDirectory(id: Int64, targetParentId: Int64) async throws
    func fileDetail(id: Int64) async throws -> DriveFileEntry
    func renameFile(id: Int64, name: String) async throws
    func moveFile(id: Int64, targetParentId: Int64) async throws
    func deleteFile(id: Int64) async throws
}

extension DriveRepository {
    // [修改] 测试桩和离线实现未提供懒加载数据时返回空列表，正式远端仓库覆盖该实现。
    func directoryChildren(id: Int64) async throws -> [DriveFileEntry] { [] }

    // [修改] 保留现有无搜索调用，统一转到服务端分页搜索接口。
    func listFiles(directoryId: Int64, page: Int, pageSize: Int) async throws -> DrivePage {
        try await listFiles(directoryId: directoryId, page: page, pageSize: pageSize, search: "")
    }

    func moveFile(id: Int64, targetParentId: Int64) async throws {
        throw DriveRepositoryError.server("当前数据源不支持文件移动")
    }
}

actor RemoteDriveRepository: DriveRepository {
    private let client: any FrameRequesting
    private let timeout: Duration

    init(client: any FrameRequesting, timeout: Duration = .seconds(15)) { self.client = client; self.timeout = timeout }

    func roots() async throws -> [DriveFileEntry] {
        let frame = try await client.request(Frame(type: .directoryListRequest), expecting: [.directoryResponse], timeout: timeout)
        // [修改] 兼容 0x15 的单根对象和多根数组两种 data 结构。
        let envelope = try decode(DriveEnvelope<DriveEntryPayload>.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
        // [修改] 成功且 data:null 与 macOS 一致表示当前没有目录，而不是协议失败。
        let entries = envelope.data?.entries ?? []
        try Self.validateIdentifiers(in: entries)
        guard entries.allSatisfy({ !$0.isFile }) else { throw DriveRepositoryError.invalidResponse }
        return entries
    }

    func directoryChildren(id: Int64) async throws -> [DriveFileEntry] {
        let request = DirectoryChildrenRequest(dirId: id)
        let frame = try await client.request(
            Frame(type: .directoryListRequest, payload: try ProtocolJSON.encoder().encode(request)),
            expecting: [.directoryResponse],
            timeout: timeout
        )
        let envelope = try decode(DriveEnvelope<DriveEntryPayload>.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
        // [修改] 叶子目录在部分服务端会返回 data:null，按空子目录处理。
        guard let data = envelope.data else { return [] }
        try Self.validateIdentifiers(in: data.entries)
        // [修改] 当前 net-server 会返回完整根树；其他版本会返回父节点或直接子节点数组，三种形态统一解包。
        if let parent = Self.entry(id: id, in: data.entries) {
            return parent.children.filter { !$0.isFile }
        }
        let directChildren = data.entries.filter { !$0.isFile }
        // [修改] 找不到请求节点时只接受 parentId 明确指向请求目录的直接子节点数组，禁止误挂整棵根树。
        guard directChildren.allSatisfy({ $0.parentId == id }) else {
            throw DriveRepositoryError.invalidResponse
        }
        return directChildren
    }

    func listFiles(directoryId: Int64, page: Int = 1, pageSize: Int = 20, search: String = "") async throws -> DrivePage {
        let request = FileListRequest(dirId: directoryId, fileName: search, pageNum: page, pageSize: pageSize)
        let frame = try await client.request(Frame(type: .fileListRequest, payload: try ProtocolJSON.encoder().encode(request)), expecting: [.fileResponse], timeout: timeout)
        let envelope = try decode(DriveEnvelope<DrivePage>.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
        // [修改] 空目录的成功响应允许 data:null，保留请求页码并返回空分页。
        let resultPage = envelope.data ?? DrivePage(
            records: [],
            currentPage: page,
            pageSize: pageSize,
            totalCount: 0,
            totalPages: 0
        )
        try Self.validateIdentifiers(in: resultPage.records)
        return resultPage
    }

    func createDirectory(parentId: Int64, name: String) async throws {
        try await operation(Frame(type: .directoryCreateRequest, payload: try ProtocolJSON.encoder().encode(CreateDirectoryRequest(pId: parentId, dirName: name))))
    }
    func renameDirectory(id: Int64, name: String) async throws {
        try await operation(Frame(type: .directoryUpdateRequest, payload: try ProtocolJSON.encoder().encode(RenameDirectoryRequest(id: id, dirName: name))))
    }
    func deleteDirectory(id: Int64) async throws {
        try await operation(Frame(type: .directoryDeleteRequest, payload: try ProtocolJSON.encoder().encode(DeleteDirectoryRequest(id: id))))
    }
    func moveDirectory(id: Int64, targetParentId: Int64) async throws {
        try await operation(Frame(
            type: .directoryMoveRequest,
            payload: try ProtocolJSON.encoder().encode(MoveDirectoryRequest(dirId: id, targetParentId: targetParentId))
        ))
    }
    func fileDetail(id: Int64) async throws -> DriveFileEntry {
        let frame = try await client.request(
            Frame(type: .fileDetailRequest, payload: try ProtocolJSON.encoder().encode(FileIDRequest(fileId: id))),
            expecting: [.fileResponse],
            timeout: timeout
        )
        let envelope = try decode(DriveEnvelope<DriveFileEntry>.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
        guard let data = envelope.data else { throw DriveRepositoryError.invalidResponse }
        guard data.id == id, data.id > 0, data.isFile else { throw DriveRepositoryError.invalidResponse }
        return data
    }
    func renameFile(id: Int64, name: String) async throws {
        try await fileOperation(Frame(type: .fileRenameRequest, payload: try ProtocolJSON.encoder().encode(RenameFileRequest(fileId: id, newFileName: name))))
    }
    func moveFile(id: Int64, targetParentId: Int64) async throws {
        try await fileOperation(Frame(
            type: .fileMoveRequest,
            payload: try ProtocolJSON.encoder().encode(MoveFileRequest(fileId: id, targetParentId: targetParentId))
        ))
    }
    func deleteFile(id: Int64) async throws {
        try await fileOperation(Frame(type: .fileDeleteRequest, payload: try ProtocolJSON.encoder().encode(FileIDRequest(fileId: id))))
    }

    private func operation(_ request: Frame) async throws {
        let frame = try await client.request(request, expecting: [.directoryResponse], timeout: timeout)
        // [修改] 新建/重命名/移动返回对象，删除返回 null；操作响应只校验状态，不强绑 data 类型。
        let envelope = try decode(DriveOperationEnvelope.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
    }

    private func fileOperation(_ request: Frame) async throws {
        let frame = try await client.request(request, expecting: [.fileResponse], timeout: timeout)
        let envelope = try decode(DriveOperationEnvelope.self, from: frame.payload)
        guard envelope.isSuccess else { throw DriveRepositoryError.server(envelope.message) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            return try ProtocolJSON.decoder().decode(type, from: payload)
        } catch {
            // [修改] JSON 结构或字段类型错误统一收敛为网盘业务错误，避免底层解码异常泄漏到 UI。
            throw DriveRepositoryError.invalidResponse
        }
    }

    private static func entry(id: Int64, in entries: [DriveFileEntry]) -> DriveFileEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if let nested = self.entry(id: id, in: entry.children) { return nested }
        }
        return nil
    }

    // [修改] 无效或重复 ID 会让目录选择、重命名和删除指向错误对象，进入状态层前统一拒绝。
    private static func validateIdentifiers(in entries: [DriveFileEntry]) throws {
        var identifiers = Set<Int64>()
        try collectAndValidateIdentifiers(in: entries, identifiers: &identifiers)
    }

    private static func collectAndValidateIdentifiers(
        in entries: [DriveFileEntry],
        identifiers: inout Set<Int64>
    ) throws {
        for entry in entries {
            guard entry.id > 0, identifiers.insert(entry.id).inserted else {
                throw DriveRepositoryError.invalidResponse
            }
            try collectAndValidateIdentifiers(in: entry.children, identifiers: &identifiers)
        }
    }
}

private struct DriveOperationEnvelope: Decodable {
    let success: Bool?
    let code: Int
    let message: String
    var isSuccess: Bool { success ?? (code == 200) }
    private enum CodingKeys: String, CodingKey { case success, code, message, msg }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? values.decodeIfPresent(String.self, forKey: .msg) ?? ""
    }
}

// [修改] 根目录和子目录接口的 data 同时兼容对象与数组。
private struct DriveEntryPayload: Decodable {
    let entries: [DriveFileEntry]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([DriveFileEntry].self) {
            entries = values
        } else {
            entries = [try container.decode(DriveFileEntry.self)]
        }
    }
}

enum DriveRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case server(String)
    case invalidResponse
    var errorDescription: String? {
        if case .server(let message) = self {
            // [修改] 服务端没有返回有效 message 时使用稳定兜底，避免空白错误弹窗。
            let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "网盘操作失败" : value
        }
        return "网盘操作失败"
    }
}

private struct DriveEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let code: Int
    let message: String
    let data: T?
    var isSuccess: Bool { success ?? (code == 200) }
    private enum CodingKeys: String, CodingKey { case success, code, message, msg, data }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        code = try values.decodeIfPresent(Int.self, forKey: .code) ?? (success == true ? 200 : 400)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? values.decodeIfPresent(String.self, forKey: .msg) ?? ""
        data = try values.decodeIfPresent(T.self, forKey: .data)
    }
}
