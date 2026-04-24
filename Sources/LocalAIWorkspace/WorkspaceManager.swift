import Foundation

public enum WorkspaceManagerError: Error, LocalizedError {
    case documentsDirectoryUnavailable
    case missingWorkspace(UUID)

    public var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "The workspace documents directory is unavailable."
        case let .missingWorkspace(id):
            return "Workspace not found: \(id.uuidString)"
        }
    }
}

public struct WorkspaceManager: Sendable {
    public let baseURL: URL
    private let fileManager: FileManager

    public init(baseURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let baseURL {
            self.baseURL = baseURL
        } else if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.baseURL = documents.appendingPathComponent("Workspaces", isDirectory: true)
        } else {
            throw WorkspaceManagerError.documentsDirectoryUnavailable
        }
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    public func createWorkspace(
        name: String,
        id: UUID = UUID(),
        mode: WorkspaceMode = .localOnly,
        activeProviderProfileID: String? = nil
    ) throws -> Workspace {
        let files = filesURL(for: id)
        let mobiledev = mobiledevURL(for: id)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mobiledev.appendingPathComponent("context"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mobiledev.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mobiledev.appendingPathComponent("github"), withIntermediateDirectories: true)
        let workspace = Workspace(
            id: id,
            name: name,
            rootPath: files.path,
            mode: mode,
            activeProviderProfileID: activeProviderProfileID,
            lastOpenedAt: .now,
            status: WorkspaceStatus(contextReady: false, cachePrefixStable: false)
        )
        try saveWorkspaceMetadata(workspace)
        try writeIfMissing(url: mobiledev.appendingPathComponent("patches.json"), data: Data("[]".utf8))
        try writeIfMissing(url: mobiledev.appendingPathComponent("agent_runs.json"), data: Data("[]".utf8))
        try writeIfMissing(url: mobiledev.appendingPathComponent("cache_records.json"), data: Data("[]".utf8))
        return workspace
    }

    public func listWorkspaces() throws -> [Workspace] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        return try contents.compactMap { url in
            let metadataURL = url.appendingPathComponent(".mobiledev/workspace.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: metadataURL))
        }
        .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public func openWorkspace(id: UUID) throws -> Workspace {
        var workspace = try loadWorkspace(id: id)
        workspace.lastOpenedAt = .now
        try saveWorkspaceMetadata(workspace)
        return workspace
    }

    public func renameWorkspace(id: UUID, to newName: String) throws -> Workspace {
        var workspace = try loadWorkspace(id: id)
        workspace.name = newName
        workspace.lastOpenedAt = .now
        try saveWorkspaceMetadata(workspace)
        return workspace
    }

    public func deleteWorkspace(id: UUID) throws {
        let url = workspaceURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw WorkspaceManagerError.missingWorkspace(id) }
        try fileManager.removeItem(at: url)
    }

    public func refreshFileTree(workspaceID: UUID) throws -> [WorkspaceFileEntry] {
        let workspace = try loadWorkspace(id: workspaceID)
        return try workspaceFS(for: workspace).listFiles()
    }

    public func updateWorkspace(_ workspace: Workspace) throws {
        try saveWorkspaceMetadata(workspace)
    }

    public func updateActiveProviderProfile(workspaceID: UUID, providerID: String?) throws -> Workspace {
        var workspace = try loadWorkspace(id: workspaceID)
        workspace.activeProviderProfileID = providerID
        workspace.lastOpenedAt = .now
        try saveWorkspaceMetadata(workspace)
        return workspace
    }

    public func workspaceFS(for workspace: Workspace) throws -> WorkspaceFS {
        try WorkspaceFS(rootURL: URL(fileURLWithPath: workspace.rootPath, isDirectory: true))
    }

    public func workspaceURL(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func filesURL(for id: UUID) -> URL {
        workspaceURL(for: id).appendingPathComponent("files", isDirectory: true)
    }

    public func mobiledevURL(for id: UUID) -> URL {
        workspaceURL(for: id).appendingPathComponent(".mobiledev", isDirectory: true)
    }

    public func loadWorkspace(id: UUID) throws -> Workspace {
        let metadataURL = mobiledevURL(for: id).appendingPathComponent("workspace.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else { throw WorkspaceManagerError.missingWorkspace(id) }
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: metadataURL))
    }

    public func saveWorkspaceMetadata(_ workspace: Workspace) throws {
        let metadataURL = mobiledevURL(for: workspace.id).appendingPathComponent("workspace.json")
        try fileManager.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(workspace)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func writeIfMissing(url: URL, data: Data) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
    }
}
