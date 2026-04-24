import Foundation

public protocol SnapshotStore: Sendable {
    func save(_ snapshot: SnapshotRecord) throws
    func snapshot(id: UUID) throws -> SnapshotRecord?
    func list(workspaceID: UUID?) throws -> [SnapshotRecord]
}

public struct FileSnapshotStore: SnapshotStore {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func save(_ snapshot: SnapshotRecord) throws {
        var snapshots = try list(workspaceID: nil)
        snapshots.removeAll { $0.id == snapshot.id }
        snapshots.append(snapshot)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(snapshots.sorted(by: { $0.createdAt < $1.createdAt })).write(to: storageURL, options: .atomic)
    }

    public func snapshot(id: UUID) throws -> SnapshotRecord? {
        try list(workspaceID: nil).first(where: { $0.id == id })
    }

    public func list(workspaceID: UUID?) throws -> [SnapshotRecord] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let snapshots = try JSONDecoder().decode([SnapshotRecord].self, from: Data(contentsOf: storageURL))
        return snapshots.filter { workspaceID == nil || $0.workspaceID == workspaceID }.sorted(by: { $0.createdAt > $1.createdAt })
    }
}
