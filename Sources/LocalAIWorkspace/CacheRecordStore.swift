import Foundation

public protocol CacheRecordStore: Sendable {
    func save(_ record: CacheRecord) throws
    func list(workspaceID: UUID?) throws -> [CacheRecord]
}

public struct FileCacheRecordStore: CacheRecordStore {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func save(_ record: CacheRecord) throws {
        var records = try list(workspaceID: nil)
        records.append(record)
        let data = try JSONEncoder.pretty.encode(records.sorted(by: { $0.createdAt < $1.createdAt }))
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
    }

    public func list(workspaceID: UUID?) throws -> [CacheRecord] {
        _ = workspaceID
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let data = try Data(contentsOf: storageURL)
        return try JSONDecoder().decode([CacheRecord].self, from: data).sorted(by: { $0.createdAt > $1.createdAt })
    }
}
