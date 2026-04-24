import Foundation

public protocol PatchStore: Sendable {
    func save(_ proposal: PatchProposal) throws
    func update(_ proposal: PatchProposal) throws
    func proposal(id: UUID) throws -> PatchProposal?
    func list(workspaceID: UUID?) throws -> [PatchProposal]
}

public struct FilePatchStore: PatchStore {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func save(_ proposal: PatchProposal) throws {
        var proposals = try load()
        proposals.removeAll { $0.id == proposal.id }
        proposals.append(proposal)
        try persist(proposals)
    }

    public func update(_ proposal: PatchProposal) throws {
        try save(proposal)
    }

    public func proposal(id: UUID) throws -> PatchProposal? {
        try load().first(where: { $0.id == id })
    }

    public func list(workspaceID: UUID?) throws -> [PatchProposal] {
        let proposals = try load().sorted(by: { $0.createdAt > $1.createdAt })
        guard let workspaceID else { return proposals }
        return proposals.filter { $0.workspaceID == workspaceID }
    }

    private func load() throws -> [PatchProposal] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let data = try Data(contentsOf: storageURL)
        return try JSONDecoder().decode([PatchProposal].self, from: data)
    }

    private func persist(_ proposals: [PatchProposal]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(proposals.sorted(by: { $0.createdAt < $1.createdAt }))
        try data.write(to: storageURL, options: .atomic)
    }
}

public final class InMemoryPatchStore: PatchStore, @unchecked Sendable {
    private let lock = NSLock()
    private var proposals: [UUID: PatchProposal] = [:]

    public init() {}

    public func save(_ proposal: PatchProposal) throws {
        lock.lock()
        defer { lock.unlock() }
        proposals[proposal.id] = proposal
    }

    public func update(_ proposal: PatchProposal) throws {
        try save(proposal)
    }

    public func proposal(id: UUID) throws -> PatchProposal? {
        lock.lock()
        defer { lock.unlock() }
        return proposals[id]
    }

    public func list(workspaceID: UUID?) throws -> [PatchProposal] {
        lock.lock()
        defer { lock.unlock() }
        return proposals.values
            .filter { workspaceID == nil || $0.workspaceID == workspaceID }
            .sorted(by: { $0.createdAt > $1.createdAt })
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
