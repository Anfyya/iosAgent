import Foundation
import LocalAIWorkspace

enum GitHubProjectImportError: Error, LocalizedError {
    case invalidRepositoryURL
    case unsupportedHost(String)
    case invalidRepositoryPath(String)
    case requestFailed(Int)
    case invalidRepositoryResponse

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL:
            return "GitHub 项目地址无效。"
        case let .unsupportedHost(host):
            return "暂时只支持 github.com 地址：\(host)"
        case let .invalidRepositoryPath(path):
            return "无法从地址中识别仓库：\(path)"
        case let .requestFailed(statusCode):
            return "GitHub 请求失败，状态码 \(statusCode)。"
        case .invalidRepositoryResponse:
            return "GitHub 返回了无法识别的仓库信息。"
        }
    }
}

struct GitHubProjectImportService {
    let workspaceManager: WorkspaceManager
    let workspaceImportService: WorkspaceImportService
    let session: URLSession

    init(
        workspaceManager: WorkspaceManager,
        workspaceImportService: WorkspaceImportService,
        session: URLSession = .shared
    ) {
        self.workspaceManager = workspaceManager
        self.workspaceImportService = workspaceImportService
        self.session = session
    }

    func importProject(from repositoryURLString: String) async throws -> Workspace {
        let repository = try parseRepositoryURL(repositoryURLString)
        let details = try await fetchRepository(owner: repository.owner, repo: repository.repo)
        let workspace = try workspaceManager.createWorkspace(name: details.repo)
        let archiveURL = URL(string: "https://codeload.github.com/\(details.owner)/\(details.repo)/zip/refs/heads/\(details.defaultBranch)")!
        let (temporaryURL, response) = try await session.download(from: archiveURL)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(statusCode) else {
            throw GitHubProjectImportError.requestFailed(statusCode)
        }

        let downloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: downloadURL)
        try FileManager.default.moveItem(at: temporaryURL, to: downloadURL)
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        _ = try workspaceImportService.importZip(sourceURL: downloadURL, workspaceID: workspace.id)
        try flattenImportedArchiveIfNeeded(workspaceID: workspace.id, repositoryName: details.repo)
        try persistRemoteConfig(for: workspace.id, details: details)
        return workspace
    }

    private func parseRepositoryURL(_ repositoryURLString: String) throws -> ParsedRepository {
        guard let url = URL(string: repositoryURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else {
            throw GitHubProjectImportError.invalidRepositoryURL
        }
        guard host == "github.com" || host == "www.github.com" else {
            throw GitHubProjectImportError.unsupportedHost(host)
        }
        let components = url.pathComponents.filter { $0 != "/" && $0.isEmpty == false }
        guard components.count >= 2 else {
            throw GitHubProjectImportError.invalidRepositoryPath(url.path)
        }
        let repo = components[1].replacingOccurrences(of: ".git", with: "")
        guard repo.isEmpty == false else {
            throw GitHubProjectImportError.invalidRepositoryPath(url.path)
        }
        return ParsedRepository(owner: components[0], repo: repo)
    }

    private func fetchRepository(owner: String, repo: String) async throws -> RepositoryDetails {
        let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(statusCode) else {
            throw GitHubProjectImportError.requestFailed(statusCode)
        }
        let payload = try JSONDecoder().decode(RepositoryPayload.self, from: data)
        guard payload.defaultBranch.isEmpty == false else {
            throw GitHubProjectImportError.invalidRepositoryResponse
        }
        return RepositoryDetails(
            owner: payload.fullName.split(separator: "/").first.map(String.init) ?? owner,
            repo: payload.fullName.split(separator: "/").last.map(String.init) ?? repo,
            defaultBranch: payload.defaultBranch,
            htmlURL: payload.htmlURL
        )
    }

    private func flattenImportedArchiveIfNeeded(workspaceID: UUID, repositoryName: String) throws {
        let filesURL = workspaceManager.filesURL(for: workspaceID)
        let topLevelEntries = try FileManager.default.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard topLevelEntries.count == 1 else { return }
        let container = topLevelEntries[0]
        let values = try container.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return }
        guard container.lastPathComponent.localizedCaseInsensitiveContains(repositoryName) else { return }
        let nestedEntries = try FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        for entry in nestedEntries {
            let destination = filesURL.appendingPathComponent(entry.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: entry, to: destination)
        }
        try FileManager.default.removeItem(at: container)
    }

    private func persistRemoteConfig(for workspaceID: UUID, details: RepositoryDetails) throws {
        let config = GitHubRemoteConfig(
            owner: details.owner,
            repo: details.repo,
            branch: details.defaultBranch,
            remoteURL: details.htmlURL,
            tokenReference: ""
        )
        let remoteURL = workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("github/remote.json")
        try FileManager.default.createDirectory(at: remoteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(config).write(to: remoteURL, options: .atomic)
    }
}

private struct ParsedRepository {
    let owner: String
    let repo: String
}

private struct RepositoryDetails {
    let owner: String
    let repo: String
    let defaultBranch: String
    let htmlURL: String
}

private struct RepositoryPayload: Decodable {
    let fullName: String
    let defaultBranch: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
    }
}