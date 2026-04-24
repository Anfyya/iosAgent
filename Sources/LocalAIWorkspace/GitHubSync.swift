import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GitHubSyncError: Error, LocalizedError {
    case missingRemoteConfig(UUID)
    case missingTokenReference(String)
    case missingToken(String)
    case pushConfirmationRequired
    case protectedBranchRequiresSecondConfirmation(String)
    case repositoryRequestFailed(statusCode: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .missingRemoteConfig(id):
            return "GitHub remote is not linked for workspace \(id.uuidString)."
        case let .missingTokenReference(reference):
            return "GitHub token reference is missing: \(reference)."
        case let .missingToken(reference):
            return "GitHub token is missing in Keychain for \(reference)."
        case .pushConfirmationRequired:
            return "Push requires explicit user confirmation."
        case let .protectedBranchRequiresSecondConfirmation(branch):
            return "Pushing \(branch) requires a second confirmation."
        case let .repositoryRequestFailed(statusCode, message):
            return "GitHub request failed with status \(statusCode): \(message)"
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        }
    }
}

public protocol GitHubAPIClient: Sendable {
    func getRepository(owner: String, repo: String, token: String) async throws -> GitHubRepository
    func getBranchRef(owner: String, repo: String, branch: String, token: String) async throws -> GitHubBranchRef
    func getLatestCommit(owner: String, repo: String, branchOrSHA: String, token: String) async throws -> GitHubCommit
    func getGitCommitTreeSHA(owner: String, repo: String, commitSHA: String, token: String) async throws -> String
    func createBlob(owner: String, repo: String, content: Data, isBinary: Bool, token: String) async throws -> String
    func createTree(owner: String, repo: String, baseTree: String?, entries: [GitTreeEntry], token: String) async throws -> String
    func createCommit(owner: String, repo: String, message: String, treeSHA: String, parents: [String], token: String) async throws -> GitHubCommit
    func updateRef(owner: String, repo: String, branch: String, sha: String, force: Bool, token: String) async throws
    func createPullRequest(owner: String, repo: String, title: String, body: String, head: String, base: String, token: String) async throws -> String
    func listWorkflows(owner: String, repo: String, token: String) async throws -> [GitHubWorkflow]
    func dispatchWorkflow(owner: String, repo: String, workflowIDOrFileName: String, ref: String, inputs: [String: String], token: String) async throws
    func listWorkflowRuns(owner: String, repo: String, branch: String?, token: String) async throws -> [GitHubWorkflowRun]
    func getWorkflowRun(owner: String, repo: String, runID: Int, token: String) async throws -> GitHubWorkflowRun
    func listJobsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubWorkflowJob]
    func listArtifactsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubArtifact]
}

public struct GitHubClient: GitHubAPIClient, Sendable {
    public let session: URLSession
    public let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func getRepository(owner: String, repo: String, token: String) async throws -> GitHubRepository {
        let payload: RepositoryPayload = try await send(path: "/repos/\(owner)/\(repo)", token: token)
        return GitHubRepository(id: payload.id, fullName: payload.fullName, private: payload.private, defaultBranch: payload.defaultBranch, htmlURL: payload.htmlURL)
    }

    public func getBranchRef(owner: String, repo: String, branch: String, token: String) async throws -> GitHubBranchRef {
        let payload: BranchRefPayload = try await send(path: "/repos/\(owner)/\(repo)/git/ref/heads/\(branch)", token: token)
        return GitHubBranchRef(ref: payload.ref, sha: payload.object.sha)
    }

    public func getLatestCommit(owner: String, repo: String, branchOrSHA: String, token: String) async throws -> GitHubCommit {
        let payload: CommitPayload = try await send(path: "/repos/\(owner)/\(repo)/commits/\(branchOrSHA)", token: token)
        return GitHubCommit(sha: payload.sha, url: payload.htmlURL, message: payload.commit.message)
    }

    public func getGitCommitTreeSHA(owner: String, repo: String, commitSHA: String, token: String) async throws -> String {
        let payload: GitCommitPayload = try await send(path: "/repos/\(owner)/\(repo)/git/commits/\(commitSHA)", token: token)
        return payload.tree.sha
    }

    public func createBlob(owner: String, repo: String, content: Data, isBinary: Bool, token: String) async throws -> String {
        struct RequestBody: Encodable { let content: String; let encoding: String }
        let body = RequestBody(content: isBinary ? content.base64EncodedString() : String(decoding: content, as: UTF8.self), encoding: isBinary ? "base64" : "utf-8")
        let payload: BlobPayload = try await send(path: "/repos/\(owner)/\(repo)/git/blobs", method: "POST", token: token, body: body)
        return payload.sha
    }

    public func createTree(owner: String, repo: String, baseTree: String?, entries: [GitTreeEntry], token: String) async throws -> String {
        struct RequestBody: Encodable {
            let base_tree: String?
            let tree: [GitTreeEntry]
        }
        let payload: TreePayload = try await send(path: "/repos/\(owner)/\(repo)/git/trees", method: "POST", token: token, body: RequestBody(base_tree: baseTree, tree: entries))
        return payload.sha
    }

    public func createCommit(owner: String, repo: String, message: String, treeSHA: String, parents: [String], token: String) async throws -> GitHubCommit {
        struct RequestBody: Encodable { let message: String; let tree: String; let parents: [String] }
        let payload: CreateCommitPayload = try await send(path: "/repos/\(owner)/\(repo)/git/commits", method: "POST", token: token, body: RequestBody(message: message, tree: treeSHA, parents: parents))
        return GitHubCommit(sha: payload.sha, url: payload.htmlURL, message: message)
    }

    public func updateRef(owner: String, repo: String, branch: String, sha: String, force: Bool = false, token: String) async throws {
        struct RequestBody: Encodable { let sha: String; let force: Bool }
        let _: EmptyPayload = try await send(path: "/repos/\(owner)/\(repo)/git/refs/heads/\(branch)", method: "PATCH", token: token, body: RequestBody(sha: sha, force: force))
    }

    public func createPullRequest(owner: String, repo: String, title: String, body: String, head: String, base: String, token: String) async throws -> String {
        struct RequestBody: Encodable { let title: String; let body: String; let head: String; let base: String }
        let payload: PullRequestPayload = try await send(path: "/repos/\(owner)/\(repo)/pulls", method: "POST", token: token, body: RequestBody(title: title, body: body, head: head, base: base))
        return payload.htmlURL
    }

    public func listWorkflows(owner: String, repo: String, token: String) async throws -> [GitHubWorkflow] {
        let payload: WorkflowListPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/workflows", token: token)
        return payload.workflows.map { GitHubWorkflow(id: $0.id, name: $0.name, path: $0.path, state: $0.state) }
    }

    public func dispatchWorkflow(owner: String, repo: String, workflowIDOrFileName: String, ref: String, inputs: [String: String], token: String) async throws {
        struct RequestBody: Encodable { let ref: String; let inputs: [String: String] }
        let _: EmptyPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/workflows/\(workflowIDOrFileName)/dispatches", method: "POST", token: token, body: RequestBody(ref: ref, inputs: inputs))
    }

    public func listWorkflowRuns(owner: String, repo: String, branch: String? = nil, token: String) async throws -> [GitHubWorkflowRun] {
        let query = branch.map { [URLQueryItem(name: "branch", value: $0)] } ?? []
        let payload: WorkflowRunsPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/runs", queryItems: query, token: token)
        return payload.workflowRuns.map {
            GitHubWorkflowRun(id: $0.id, name: $0.name, workflowID: $0.workflowID, status: $0.status, conclusion: $0.conclusion, headBranch: $0.headBranch, headSHA: $0.headSHA, htmlURL: $0.htmlURL, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }

    public func getWorkflowRun(owner: String, repo: String, runID: Int, token: String) async throws -> GitHubWorkflowRun {
        let payload: WorkflowRunPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)", token: token)
        return GitHubWorkflowRun(id: payload.id, name: payload.name, workflowID: payload.workflowID, status: payload.status, conclusion: payload.conclusion, headBranch: payload.headBranch, headSHA: payload.headSHA, htmlURL: payload.htmlURL, createdAt: payload.createdAt, updatedAt: payload.updatedAt)
    }

    public func listJobsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubWorkflowJob] {
        let payload: JobsPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs", token: token)
        return payload.jobs.map { GitHubWorkflowJob(id: $0.id, name: $0.name, status: $0.status, conclusion: $0.conclusion, startedAt: $0.startedAt, completedAt: $0.completedAt) }
    }

    public func listArtifactsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubArtifact] {
        let payload: ArtifactsPayload = try await send(path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)/artifacts", token: token)
        return payload.artifacts.map {
            GitHubArtifact(id: $0.id, name: $0.name, sizeInBytes: $0.sizeInBytes, expired: $0.expired, archiveDownloadURL: $0.archiveDownloadURL, browserDownloadURL: $0.archiveDownloadURL)
        }
    }

    private func send<Response: Decodable>(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], token: String) async throws -> Response {
        try await send(path: path, method: method, queryItems: queryItems, token: token, body: Optional<EmptyPayload>.none)
    }

    private func send<Response: Decodable, Body: Encodable>(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], token: String, body: Body? = nil) async throws -> Response {
        guard var components = URLComponents(string: "https://api.github.com\(path)") else {
            throw GitHubSyncError.invalidResponse
        }
        if queryItems.isEmpty == false {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GitHubSyncError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(statusCode) else {
            let message = (try? decoder.decode(GitHubErrorPayload.self, from: data).message) ?? String(decoding: data, as: UTF8.self)
            throw GitHubSyncError.repositoryRequestFailed(statusCode: statusCode, message: message)
        }
        if Response.self == EmptyPayload.self, data.isEmpty {
            return EmptyPayload() as! Response
        }
        if Response.self == EmptyPayload.self, let value = try? decoder.decode(EmptyPayload.self, from: data) {
            return value as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }
}

public struct GitTreeEntry: Encodable, Hashable, Sendable {
    public var path: String
    public var mode: String
    public var type: String
    public var sha: String

    public init(path: String, mode: String = "100644", type: String = "blob", sha: String) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
    }
}

public struct GitHubSyncService: Sendable {
    public static let secretService = "LocalAIWorkspace.github"

    public let workspaceManager: WorkspaceManager
    public let secretStore: any SecretStore
    public let client: any GitHubAPIClient
    public let maximumBlobSizeBytes: Int

    public init(workspaceManager: WorkspaceManager, secretStore: any SecretStore, client: any GitHubAPIClient = GitHubClient(), maximumBlobSizeBytes: Int = 1_000_000) {
        self.workspaceManager = workspaceManager
        self.secretStore = secretStore
        self.client = client
        self.maximumBlobSizeBytes = maximumBlobSizeBytes
    }

    public func linkRepository(workspaceID: UUID, owner: String, repo: String, branch: String, token: String, tokenReference: String? = nil) async throws -> GitHubRemoteConfig {
        let repository = try await client.getRepository(owner: owner, repo: repo, token: token)
        let reference = tokenReference ?? "github.default"
        try secretStore.save(service: Self.secretService, account: reference, value: token)
        let config = GitHubRemoteConfig(owner: owner, repo: repo, branch: branch.isEmpty ? repository.defaultBranch : branch, remoteURL: repository.htmlURL, tokenReference: reference, lastCommitSHA: nil, linkedAt: .now, updatedAt: .now)
        try saveRemoteConfig(config, workspaceID: workspaceID)
        return config
    }

    public func loadRemoteConfig(workspaceID: UUID) throws -> GitHubRemoteConfig {
        let url = remoteConfigURL(for: workspaceID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GitHubSyncError.missingRemoteConfig(workspaceID)
        }
        return try JSONDecoder().decode(GitHubRemoteConfig.self, from: Data(contentsOf: url))
    }

    public func getRepository(workspaceID: UUID) async throws -> GitHubRepository {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.getRepository(owner: remote.owner, repo: remote.repo, token: try token(for: remote))
    }

    public func getBranchRef(workspaceID: UUID) async throws -> GitHubBranchRef {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.getBranchRef(owner: remote.owner, repo: remote.repo, branch: remote.branch, token: try token(for: remote))
    }

    public func getLatestCommit(workspaceID: UUID) async throws -> GitHubCommit {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.getLatestCommit(owner: remote.owner, repo: remote.repo, branchOrSHA: remote.branch, token: try token(for: remote))
    }

    public func createBlob(workspaceID: UUID, content: Data, isBinary: Bool) async throws -> String {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.createBlob(owner: remote.owner, repo: remote.repo, content: content, isBinary: isBinary, token: try token(for: remote))
    }

    public func createTree(workspaceID: UUID, baseTree: String?, entries: [GitTreeEntry]) async throws -> String {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.createTree(owner: remote.owner, repo: remote.repo, baseTree: baseTree, entries: entries, token: try token(for: remote))
    }

    public func createCommit(workspaceID: UUID, message: String, treeSHA: String, parents: [String]) async throws -> GitHubCommit {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.createCommit(owner: remote.owner, repo: remote.repo, message: message, treeSHA: treeSHA, parents: parents, token: try token(for: remote))
    }

    public func updateRef(workspaceID: UUID, sha: String) async throws {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        try await client.updateRef(owner: remote.owner, repo: remote.repo, branch: remote.branch, sha: sha, force: false, token: try token(for: remote))
        var updated = remote
        updated.lastCommitSHA = sha
        updated.updatedAt = .now
        try saveRemoteConfig(updated, workspaceID: workspaceID)
    }

    public func commitWorkspaceChanges(workspaceID: UUID, message: String, includeBinaryFiles: Bool = false, includeLargeFiles: Bool = false) async throws -> GitHubCommitSummary {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        let token = try token(for: remote)
        let workspace = try workspaceManager.loadWorkspace(id: workspaceID)
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let branchRef = try await client.getBranchRef(owner: remote.owner, repo: remote.repo, branch: remote.branch, token: token)
        let baseTreeSHA = try await client.getGitCommitTreeSHA(owner: remote.owner, repo: remote.repo, commitSHA: branchRef.sha, token: token)
        let payload = try await buildTreePayload(workspaceFS: fs, workspaceID: workspaceID, remote: remote, token: token)
        let treeSHA = try await client.createTree(owner: remote.owner, repo: remote.repo, baseTree: baseTreeSHA, entries: payload.entries, token: token)
        let commit = try await client.createCommit(owner: remote.owner, repo: remote.repo, message: message, treeSHA: treeSHA, parents: [branchRef.sha], token: token)
        return GitHubCommitSummary(remote: remote, headSHA: commit.sha, changedFiles: payload.changedFiles, skippedFiles: payload.skippedFiles, warnings: payload.warnings)
    }

    public func pushWorkspaceToBranch(workspaceID: UUID, message: String, confirmed: Bool, secondProtectedBranchConfirmation: Bool = false, includeBinaryFiles: Bool = false, includeLargeFiles: Bool = false) async throws -> GitHubCommitSummary {
        guard confirmed else { throw GitHubSyncError.pushConfirmationRequired }
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        if ["main", "master"].contains(remote.branch), secondProtectedBranchConfirmation == false {
            throw GitHubSyncError.protectedBranchRequiresSecondConfirmation(remote.branch)
        }
        let summary = try await commitWorkspaceChanges(workspaceID: workspaceID, message: message, includeBinaryFiles: includeBinaryFiles, includeLargeFiles: includeLargeFiles)
        try await updateRef(workspaceID: workspaceID, sha: summary.headSHA)
        return summary
    }

    public func createPullRequest(workspaceID: UUID, title: String, body: String, head: String, base: String) async throws -> String {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.createPullRequest(owner: remote.owner, repo: remote.repo, title: title, body: body, head: head, base: base, token: try token(for: remote))
    }

    public func listWorkflows(workspaceID: UUID) async throws -> [GitHubWorkflow] {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.listWorkflows(owner: remote.owner, repo: remote.repo, token: try token(for: remote))
    }

    public func dispatchWorkflow(workspaceID: UUID, workflowIDOrFileName: String, ref: String, inputs: [String: String]) async throws {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        try await client.dispatchWorkflow(owner: remote.owner, repo: remote.repo, workflowIDOrFileName: workflowIDOrFileName, ref: ref, inputs: inputs, token: try token(for: remote))
    }

    public func listWorkflowRuns(workspaceID: UUID) async throws -> [GitHubWorkflowRun] {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.listWorkflowRuns(owner: remote.owner, repo: remote.repo, branch: nil, token: try token(for: remote))
    }

    public func getWorkflowRun(workspaceID: UUID, runID: Int) async throws -> GitHubWorkflowRun {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.getWorkflowRun(owner: remote.owner, repo: remote.repo, runID: runID, token: try token(for: remote))
    }

    public func listJobsForRun(workspaceID: UUID, runID: Int) async throws -> [GitHubWorkflowJob] {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.listJobsForRun(owner: remote.owner, repo: remote.repo, runID: runID, token: try token(for: remote))
    }

    public func listArtifactsForRun(workspaceID: UUID, runID: Int) async throws -> [GitHubArtifact] {
        let remote = try loadRemoteConfig(workspaceID: workspaceID)
        return try await client.listArtifactsForRun(owner: remote.owner, repo: remote.repo, runID: runID, token: try token(for: remote))
    }

    public func downloadArtifactMetadata(workspaceID: UUID, artifactID: Int) async throws -> GitHubArtifact {
        let artifacts = try await listWorkflowRuns(workspaceID: workspaceID)
        for run in artifacts.prefix(20) {
            let runArtifacts = try await listArtifactsForRun(workspaceID: workspaceID, runID: run.id)
            if let artifact = runArtifacts.first(where: { $0.id == artifactID }) {
                return artifact
            }
        }
        throw GitHubSyncError.invalidResponse
    }

    private func buildTreePayload(workspaceFS: WorkspaceFS, workspaceID: UUID, remote: GitHubRemoteConfig, token: String) async throws -> (entries: [GitTreeEntry], changedFiles: [GitHubFileSummary], skippedFiles: [GitHubFileSummary], warnings: [String]) {
        let entries = try workspaceFS.listFiles().sorted(by: { $0.path < $1.path }).filter { !$0.isDirectory && !$0.path.hasPrefix(".mobiledev") }
        var treeEntries: [GitTreeEntry] = []
        var changedFiles: [GitHubFileSummary] = []
        var skippedFiles: [GitHubFileSummary] = []
        var warnings: [String] = []

        for entry in entries {
            let url = try workspaceFS.safeURL(for: entry.path, requiresProtectedPathAccess: true)
            let data = try Data(contentsOf: url)
            let isBinary = data.prefix(512).contains(0)
            if isBinary {
                skippedFiles.append(GitHubFileSummary(path: entry.path, size: entry.size, isBinary: true, skippedReason: "Binary files require explicit confirmation."))
                continue
            }
            if Int(entry.size) > maximumBlobSizeBytes {
                skippedFiles.append(GitHubFileSummary(path: entry.path, size: entry.size, isBinary: false, skippedReason: "File exceeds upload size limit."))
                continue
            }
            let blobSHA = try await client.createBlob(owner: remote.owner, repo: remote.repo, content: data, isBinary: false, token: token)
            treeEntries.append(GitTreeEntry(path: entry.path, sha: blobSHA))
            changedFiles.append(GitHubFileSummary(path: entry.path, size: entry.size, isBinary: false))
        }

        if changedFiles.isEmpty {
            warnings.append("No eligible files were included in the GitHub commit payload.")
        }
        return (treeEntries, changedFiles, skippedFiles, warnings)
    }

    private func saveRemoteConfig(_ config: GitHubRemoteConfig, workspaceID: UUID) throws {
        let url = remoteConfigURL(for: workspaceID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(config).write(to: url, options: .atomic)
    }

    private func remoteConfigURL(for workspaceID: UUID) -> URL {
        workspaceManager.mobiledevURL(for: workspaceID).appendingPathComponent("github/remote.json")
    }

    private func token(for remote: GitHubRemoteConfig) throws -> String {
        guard remote.tokenReference.isEmpty == false else {
            throw GitHubSyncError.missingTokenReference(remote.tokenReference)
        }
        guard let token = try secretStore.read(service: Self.secretService, account: remote.tokenReference) else {
            throw GitHubSyncError.missingToken(remote.tokenReference)
        }
        return token
    }
}

private struct EmptyPayload: Codable {}
private struct GitHubErrorPayload: Decodable { let message: String }
private struct RepositoryPayload: Decodable {
    let id: Int
    let fullName: String
    let `private`: Bool
    let defaultBranch: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case `private`
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
    }
}
private struct BranchRefPayload: Decodable { struct RefObject: Decodable { let sha: String }; let ref: String; let object: RefObject }
private struct CommitPayload: Decodable {
    struct InnerCommit: Decodable { let message: String }
    let sha: String
    let htmlURL: String?
    let commit: InnerCommit
    enum CodingKeys: String, CodingKey { case sha; case htmlURL = "html_url"; case commit }
}
private struct GitCommitPayload: Decodable { struct Tree: Decodable { let sha: String }; let tree: Tree }
private struct BlobPayload: Decodable { let sha: String }
private struct TreePayload: Decodable { let sha: String }
private struct CreateCommitPayload: Decodable { let sha: String; let htmlURL: String?; enum CodingKeys: String, CodingKey { case sha; case htmlURL = "html_url" } }
private struct PullRequestPayload: Decodable { let htmlURL: String; enum CodingKeys: String, CodingKey { case htmlURL = "html_url" } }
private struct WorkflowListPayload: Decodable { let workflows: [WorkflowPayload] }
private struct WorkflowPayload: Decodable { let id: Int; let name: String; let path: String; let state: String }
private struct WorkflowRunsPayload: Decodable { let workflowRuns: [WorkflowRunPayload]; enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" } }
private struct WorkflowRunPayload: Decodable {
    let id: Int
    let name: String?
    let workflowID: Int?
    let status: String?
    let conclusion: String?
    let headBranch: String?
    let headSHA: String?
    let htmlURL: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case workflowID = "workflow_id"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
private struct JobsPayload: Decodable { let jobs: [JobPayload] }
private struct JobPayload: Decodable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    enum CodingKeys: String, CodingKey { case id, name, status, conclusion; case startedAt = "started_at"; case completedAt = "completed_at" }
}
private struct ArtifactsPayload: Decodable { let artifacts: [ArtifactPayload] }
private struct ArtifactPayload: Decodable {
    let id: Int
    let name: String
    let sizeInBytes: Int
    let expired: Bool
    let archiveDownloadURL: String
    enum CodingKeys: String, CodingKey { case id, name, expired; case sizeInBytes = "size_in_bytes"; case archiveDownloadURL = "archive_download_url" }
}
