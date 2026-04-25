import Foundation

public enum ImportConflictPolicy: String, Codable, CaseIterable, Sendable {
    case overwrite
    case keepBoth
    case cancel
}

public enum ImportedItemStatus: String, Codable, CaseIterable, Sendable {
    case imported
    case overwritten
    case duplicated
    case skipped
}

public struct ImportedItemResult: Codable, Hashable, Sendable {
    public var sourcePath: String
    public var destinationPath: String?
    public var status: ImportedItemStatus
    public var message: String?

    public init(sourcePath: String, destinationPath: String? = nil, status: ImportedItemStatus, message: String? = nil) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.message = message
    }
}

public struct WorkspaceImportResult: Codable, Hashable, Sendable {
    public var items: [ImportedItemResult]
    public var warnings: [String]

    public init(items: [ImportedItemResult], warnings: [String] = []) {
        self.items = items
        self.warnings = warnings
    }

    public var importedCount: Int {
        items.filter { [.imported, .overwritten, .duplicated].contains($0.status) }.count
    }
}

public struct GitHubRemoteConfig: Codable, Hashable, Sendable {
    public var owner: String
    public var repo: String
    public var branch: String
    public var remoteURL: String
    public var tokenReference: String
    public var lastCommitSHA: String?
    public var linkedAt: Date
    public var updatedAt: Date

    public init(owner: String, repo: String, branch: String, remoteURL: String, tokenReference: String, lastCommitSHA: String? = nil, linkedAt: Date = Date(), updatedAt: Date = Date()) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.remoteURL = remoteURL
        self.tokenReference = tokenReference
        self.lastCommitSHA = lastCommitSHA
        self.linkedAt = linkedAt
        self.updatedAt = updatedAt
    }
}

public struct GitHubRepository: Codable, Hashable, Sendable {
    public var id: Int
    public var fullName: String
    public var `private`: Bool
    public var defaultBranch: String
    public var htmlURL: String

    public init(id: Int, fullName: String, private: Bool, defaultBranch: String, htmlURL: String) {
        self.id = id
        self.fullName = fullName
        self.private = `private`
        self.defaultBranch = defaultBranch
        self.htmlURL = htmlURL
    }
}

public struct GitHubBranchRef: Codable, Hashable, Sendable {
    public var ref: String
    public var sha: String

    public init(ref: String, sha: String) {
        self.ref = ref
        self.sha = sha
    }
}

public struct GitHubCommit: Codable, Hashable, Sendable {
    public var sha: String
    public var url: String?
    public var message: String?

    public init(sha: String, url: String? = nil, message: String? = nil) {
        self.sha = sha
        self.url = url
        self.message = message
    }
}

public struct GitHubWorkflow: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var path: String
    public var state: String

    public init(id: Int, name: String, path: String, state: String) {
        self.id = id
        self.name = name
        self.path = path
        self.state = state
    }
}

public struct GitHubWorkflowRun: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String?
    public var workflowID: Int?
    public var status: String?
    public var conclusion: String?
    public var headBranch: String?
    public var headSHA: String?
    public var htmlURL: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: Int, name: String? = nil, workflowID: Int? = nil, status: String? = nil, conclusion: String? = nil, headBranch: String? = nil, headSHA: String? = nil, htmlURL: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.workflowID = workflowID
        self.status = status
        self.conclusion = conclusion
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.htmlURL = htmlURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GitHubWorkflowJob: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var status: String?
    public var conclusion: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: Int, name: String, status: String? = nil, conclusion: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct GitHubArtifact: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var sizeInBytes: Int
    public var expired: Bool
    public var archiveDownloadURL: String
    public var browserDownloadURL: String?

    public init(id: Int, name: String, sizeInBytes: Int, expired: Bool, archiveDownloadURL: String, browserDownloadURL: String? = nil) {
        self.id = id
        self.name = name
        self.sizeInBytes = sizeInBytes
        self.expired = expired
        self.archiveDownloadURL = archiveDownloadURL
        self.browserDownloadURL = browserDownloadURL
    }
}

public struct GitHubFileSummary: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var isBinary: Bool
    public var skippedReason: String?

    public init(path: String, size: Int64, isBinary: Bool, skippedReason: String? = nil) {
        self.path = path
        self.size = size
        self.isBinary = isBinary
        self.skippedReason = skippedReason
    }
}

public struct GitHubCommitSummary: Codable, Hashable, Sendable {
    public var remote: GitHubRemoteConfig
    public var headSHA: String
    public var changedFiles: [GitHubFileSummary]
    public var skippedFiles: [GitHubFileSummary]
    public var warnings: [String]

    public init(remote: GitHubRemoteConfig, headSHA: String, changedFiles: [GitHubFileSummary], skippedFiles: [GitHubFileSummary], warnings: [String]) {
        self.remote = remote
        self.headSHA = headSHA
        self.changedFiles = changedFiles
        self.skippedFiles = skippedFiles
        self.warnings = warnings
    }
}

public struct BuildDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var workflow: String
    public var ref: String?
    public var artifact: String?
    public var inputs: [String: String]

    public init(id: UUID = UUID(), name: String, workflow: String, ref: String? = nil, artifact: String? = nil, inputs: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.workflow = workflow
        self.ref = ref
        self.artifact = artifact
        self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case workflow
        case ref
        case artifact
        case inputs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        workflow = try container.decode(String.self, forKey: .workflow)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        artifact = try container.decodeIfPresent(String.self, forKey: .artifact)
        inputs = try container.decodeIfPresent([String: String].self, forKey: .inputs) ?? [:]
    }
}

public struct BuildConfiguration: Codable, Hashable, Sendable {
    public var name: String
    public var builds: [BuildDefinition]

    public init(name: String, builds: [BuildDefinition]) {
        self.name = name
        self.builds = builds
    }
}

public struct PromptBuildOutput: Hashable, Sendable {
    public var systemMessage: String
    public var contextMessage: String
    public var messages: [AIMessage]

    public init(systemMessage: String, contextMessage: String, messages: [AIMessage]) {
        self.systemMessage = systemMessage
        self.contextMessage = contextMessage
        self.messages = messages
    }
}

public struct AuditLogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var action: String
    public var target: String?
    public var metadata: [String: JSONValue]
    public var createdAt: Date

    public init(id: UUID = UUID(), action: String, target: String? = nil, metadata: [String: JSONValue] = [:], createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.target = target
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public extension ProviderProfile {
    func exportedData(prettyPrinted: Bool = true) throws -> Data {
        var sanitized = self
        sanitized.apiKeyReference = nil
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(sanitized)
    }

    static func imported(from data: Data) throws -> ProviderProfile {
        var profile = try JSONDecoder().decode(ProviderProfile.self, from: data)
        profile.apiKeyReference = nil
        return profile
    }
}

public extension JSONValue {
    var stringDescription: String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .integer(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case let .object(value):
            return value.keys.sorted().map { key in
                let rendered = value[key]?.stringDescription ?? ""
                return "\(key): \(rendered)"
            }.joined(separator: ", ")
        case let .array(values):
            return values.map(\.stringDescription).joined(separator: ", ")
        case .null:
            return "null"
        }
    }
}
