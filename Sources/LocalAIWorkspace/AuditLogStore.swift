import Foundation

public protocol AuditLogStore: Sendable {
    func append(_ entry: AuditLogEntry) throws
    func recent(limit: Int) throws -> [AuditLogEntry]
}

public struct FileAuditLogStore: AuditLogStore {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func append(_ entry: AuditLogEntry) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: storageURL.path) {
            let handle = try FileHandle(forWritingTo: storageURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: storageURL, options: .atomic)
        }
    }

    public func recent(limit: Int = 100) throws -> [AuditLogEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = String(decoding: try Data(contentsOf: storageURL), as: UTF8.self)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        return try lines.compactMap { line in
            try decoder.decode(AuditLogEntry.self, from: Data(line.utf8))
        }.sorted(by: { $0.createdAt > $1.createdAt })
    }
}
