import Foundation
import UniformTypeIdentifiers

struct DriveFileEntry: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let parentId: Int64
    let name: String
    let path: String
    let parentDirectoryName: String?
    let size: Int64?
    let fileType: String
    let isFile: Bool
    let hasChildren: Bool
    let createdAt: Int64?
    let modifiedAt: Int64?
    let md5: String?
    let children: [DriveFileEntry]

    init(
        id: Int64,
        parentId: Int64,
        name: String,
        path: String = "",
        parentDirectoryName: String? = nil,
        size: Int64?,
        fileType: String,
        isFile: Bool,
        hasChildren: Bool,
        createdAt: Int64? = nil,
        modifiedAt: Int64?,
        md5: String? = nil,
        children: [DriveFileEntry] = []
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.path = path
        self.parentDirectoryName = parentDirectoryName
        self.size = size
        self.fileType = fileType
        self.isFile = isFile
        self.hasChildren = hasChildren
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.md5 = md5
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DriveCodingKey.self)
        id = try values.first(Int64.self, ["id"]) ?? 0
        parentId = try values.first(Int64.self, ["pId", "parentId"]) ?? 0
        name = try values.first(String.self, ["fileName", "name"]) ?? "未命名"
        path = try values.first(String.self, ["filePath", "path"]) ?? ""
        parentDirectoryName = try values.first(String.self, ["parentDirName", "parentDirectoryName"])
        size = try values.first(Int64.self, ["fileSize", "size"])
        fileType = try values.first(String.self, ["fileType"]) ?? ""
        isFile = try values.bool(["isFile"], default: false)
        let childFileListKey = DriveCodingKey("childFileList")
        let childrenKey = DriveCodingKey("children")
        let hasExplicitChildren = values.contains(childFileListKey) || values.contains(childrenKey)
        // [修改] 服务端目录树递归放在 childFileList，不能只保留 hasChild 标记。
        children = try values.decodeIfPresent([DriveFileEntry].self, forKey: childFileListKey)
            ?? values.decodeIfPresent([DriveFileEntry].self, forKey: childrenKey)
            ?? []
        let flaggedHasChildren = try values.bool(["hasChild", "hasChildren"], default: false)
        // [修改] 完整树明确返回空数组时以数组为准；仅省略数组的懒加载响应才采用 hasChild。
        hasChildren = hasExplicitChildren ? !children.isEmpty : flaggedHasChildren
        createdAt = try values.first(Int64.self, ["gmtCreated", "createdAt"])
        modifiedAt = try values.first(Int64.self, ["gmtModified", "modifiedAt"])
        md5 = try values.first(String.self, ["md5"])
    }
}

// [修改] 智能集合只对当前已加载目录做本地筛选，不改变服务端目录结构和分页协议。
enum DriveSmartCollection: String, CaseIterable, Identifiable, Sendable {
    case all
    case recent
    case images
    case videos
    case largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .recent: return "最近"
        case .images: return "图片"
        case .videos: return "视频"
        case .largeFiles: return "大文件"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .recent: return "clock"
        case .images: return "photo"
        case .videos: return "play.rectangle"
        case .largeFiles: return "externaldrive.badge.exclamationmark"
        }
    }
}

// [修改] 网盘分享到动态只建立远端引用，保留现有 fileId，禁止重复走上传链路。
enum DriveDynamicDraftBuilder {
    static func draft(for entry: DriveFileEntry) -> DynamicComposerDraft? {
        guard entry.isFile, entry.id > 0 else { return nil }
        let kind: DynamicMediaKind
        if DriveFileOpenRules.isImage(entry) {
            kind = .image
        } else if DriveFileOpenRules.isVideo(entry) {
            kind = .video
        } else {
            kind = .file
        }
        let media = DynamicMedia(
            kind: kind,
            fileId: entry.id,
            fileName: entry.name,
            fileSize: entry.size ?? 0,
            mimeType: mimeType(for: entry, kind: kind)
        )
        let reference = DynamicReference(
            sourceType: .driveFile,
            sourceId: String(entry.id),
            title: entry.name,
            subtitle: ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file),
            media: [media]
        )
        return DynamicComposerDraft(reference: reference)
    }

    private static func mimeType(for entry: DriveFileEntry, kind: DynamicMediaKind) -> String {
        let normalizedType = entry.fileType.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedType.contains("/") { return normalizedType }
        let fileExtension = DriveFileOpenRules.fileExtension(for: entry)
        switch kind {
        case .image: return fileExtension.isEmpty ? "image/*" : "image/\(fileExtension)"
        case .video: return fileExtension.isEmpty ? "video/*" : "video/\(fileExtension)"
        case .file: return "application/octet-stream"
        }
    }
}

// [修改] 与 macOS 共用同一套重命名体感：编辑主文件名，保存时保留原扩展名。
enum DriveFileNameRules {
    // [修改] 业务支持但系统 UTType 未必注册的扩展名也必须按真实扩展名拦截。
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "gif", "webp",
        "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]

    static func editableName(for entry: DriveFileEntry) -> String {
        guard entry.isFile else { return entry.name }
        let fileExtension = normalizedExtension(from: entry.name)
        guard !fileExtension.isEmpty else { return entry.name }
        return (entry.name as NSString).deletingPathExtension
    }

    static func applyingPreservedExtension(to editedName: String, originalFileName: String) -> String {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let originalExtension = normalizedExtension(from: originalFileName)
        guard !originalExtension.isEmpty else { return trimmed }
        // [修改] 文件重命名只能改主文件名，任何调用入口都必须保留原扩展名。
        return "\(trimmed).\(originalExtension)"
    }

    static func containsRegisteredExtension(_ value: String) -> Bool {
        let fileExtension = normalizedExtension(from: value)
        guard !fileExtension.isEmpty else { return false }
        if supportedExtensions.contains(fileExtension) { return true }
        guard let contentType = UTType(filenameExtension: fileExtension) else {
            return false
        }
        // [修改] final、v2 这类点号后缀是动态类型，仍属于主文件名；只拦截 PDF、MOV 等真实扩展名。
        return !contentType.isDynamic
    }

    private static func normalizedExtension(from value: String) -> String {
        (value as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// [修改] 系统文件选择器只有用户主动取消可以静默，权限或文件提供器错误必须反馈。
enum DrivePickerErrorRules {
    static func message(for error: Error, fallback: String) -> String? {
        if error is CancellationError { return nil }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSUserCancelledError {
            return nil
        }
        return fallback
    }
}

enum DriveFileOpenPresentation: Equatable {
    case inlineMedia
    case quickLook
}

// [修改] 图片和视频沿用媒体预览，其他可下载文件统一交给系统 Quick Look 打开。
enum DriveFileOpenRules {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    static func presentation(for entry: DriveFileEntry) -> DriveFileOpenPresentation {
        isImage(entry) || isVideo(entry) ? .inlineMedia : .quickLook
    }

    static func isImage(_ entry: DriveFileEntry) -> Bool {
        imageExtensions.contains(fileExtension(for: entry))
    }

    static func isVideo(_ entry: DriveFileEntry) -> Bool {
        videoExtensions.contains(fileExtension(for: entry))
    }

    static func fileExtension(for entry: DriveFileEntry) -> String {
        let raw = entry.fileType.split(separator: "/").last.map(String.init) ?? entry.fileType
        let type = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !type.isEmpty { return type }
        return (entry.name as NSString).pathExtension.lowercased()
    }
}

struct DrivePage: Decodable, Equatable, Sendable {
    let records: [DriveFileEntry]
    let currentPage: Int
    let pageSize: Int
    let totalCount: Int64
    let totalPages: Int

    init(records: [DriveFileEntry], currentPage: Int, pageSize: Int, totalCount: Int64, totalPages: Int? = nil) {
        self.records = records
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.totalCount = totalCount
        self.totalPages = totalPages ?? (pageSize > 0 ? Int((totalCount + Int64(pageSize) - 1) / Int64(pageSize)) : 0)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DriveCodingKey.self)
        records = try values.decodeIfPresent([DriveFileEntry].self, forKey: DriveCodingKey("recordList"))
            ?? values.decodeIfPresent([DriveFileEntry].self, forKey: DriveCodingKey("records")) ?? []
        currentPage = try values.first(Int.self, ["currentPage", "pageNum"]) ?? 1
        pageSize = try values.first(Int.self, ["pageSize"]) ?? records.count
        totalCount = try values.first(Int64.self, ["totalCount", "total"]) ?? Int64(records.count)
        totalPages = try values.first(Int.self, ["totalPage", "totalPages"])
            ?? (pageSize > 0 ? Int((totalCount + Int64(pageSize) - 1) / Int64(pageSize)) : 0)
    }
}

struct DirectoryChildrenRequest: Codable, Sendable { let dirId: Int64 }
struct CreateDirectoryRequest: Codable, Sendable { let pId: Int64; let dirName: String }
struct RenameDirectoryRequest: Codable, Sendable { let id: Int64; let dirName: String }
struct DeleteDirectoryRequest: Codable, Sendable { let id: Int64 }
struct MoveDirectoryRequest: Codable, Sendable { let dirId: Int64; let targetParentId: Int64 }
struct FileListRequest: Codable, Sendable { let dirId: Int64; let fileName: String; let pageNum: Int; let pageSize: Int }
struct FileIDRequest: Codable, Sendable { let fileId: Int64 }
struct RenameFileRequest: Codable, Sendable { let fileId: Int64; let newFileName: String }

private struct DriveCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == DriveCodingKey {
    func first<T: Decodable>(_ type: T.Type, _ names: [String]) throws -> T? {
        for name in names {
            let key = DriveCodingKey(name)
            guard contains(key) else { continue }
            do {
                if let value = try decodeIfPresent(type, forKey: key) { return value }
            } catch {
                // [修改] 服务端同一字段会混用 JSON 数字和数字字符串，与 macOS 解码规则保持一致。
                if type == Int.self,
                   let rawValue = try? decode(String.self, forKey: key),
                   let value = Int(rawValue) as? T {
                    return value
                }
                if type == Int64.self,
                   let rawValue = try? decode(String.self, forKey: key),
                   let value = Int64(rawValue) as? T {
                    return value
                }
                throw error
            }
        }
        return nil
    }
    func bool(_ names: [String], default fallback: Bool) throws -> Bool {
        if let value = try? first(Bool.self, names) { return value }
        if let value = try? first(Int.self, names) { return value != 0 }
        if let value = try? first(String.self, names) { return ["y", "yes", "true", "1"].contains(value.lowercased()) }
        return fallback
    }
}
