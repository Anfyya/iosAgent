import Foundation

public struct BuildConfigLoader: Sendable {
    public let workspaceManager: WorkspaceManager

    public init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    public func load(workspaceID: UUID) throws -> BuildConfiguration? {
        let candidates = [
            workspaceManager.filesURL(for: workspaceID).appendingPathComponent(".mobiledev/builds.json"),
            workspaceManager.filesURL(for: workspaceID).appendingPathComponent("mobiledev-builds.json"),
            workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("github/builds.json")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try JSONDecoder().decode(BuildConfiguration.self, from: Data(contentsOf: candidate))
        }
        return nil
    }
}
