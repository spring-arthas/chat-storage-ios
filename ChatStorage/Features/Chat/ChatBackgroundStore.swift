import Foundation

actor ChatBackgroundStore {
    static let shared = ChatBackgroundStore()
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = base.appendingPathComponent("ChatBackgrounds", isDirectory: true)
    }

    func load(friendId: Int64) throws -> Data? {
        let url = fileURL(friendId: friendId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data, friendId: Int64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(friendId: friendId), options: .atomic)
    }

    func remove(friendId: Int64) throws {
        let url = fileURL(friendId: friendId)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fileURL(friendId: Int64) -> URL {
        directory.appendingPathComponent("\(friendId).image")
    }
}
