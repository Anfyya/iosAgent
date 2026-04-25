import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var rawValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .integer(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(\.rawValue)
        case let .array(value): return value.map(\.rawValue)
        case .null: return NSNull()
        }
    }
}

public enum WorkspaceMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case linkedToGitHub
    case githubMirror
}

public struct WorkspaceStatus: Codable, Hashable, Sendable {
    public var contextReady: Bool
    public var cachePrefixStable: Bool
    public var lastAIRunAt: Date?
    public var lastSnapshotAt: Date?

    public init(contextReady: Bool, cachePrefixStable: Bool, lastAIRunAt: Date? = nil, lastSnapshotAt: Date? = nil) {
        self.contextReady = contextReady
        self.cachePrefixStable = cachePrefixStable
        self.lastAIRunAt = lastAIRunAt
        self.lastSnapshotAt = lastSnapshotAt
    }
}

public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var mode: WorkspaceMode
    public var currentBranch: String?
    public var githubRemote: String?
    public var activeProviderProfileID: String?
    public var lastOpenedAt: Date?
    public var status: WorkspaceStatus

    public init(id: UUID = UUID(), name: String, rootPath: String, mode: WorkspaceMode, currentBranch: String? = nil, githubRemote: String? = nil, activeProviderProfileID: String? = nil, lastOpenedAt: Date? = nil, status: WorkspaceStatus) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.mode = mode
        self.currentBranch = currentBranch
        self.githubRemote = githubRemote
        self.activeProviderProfileID = activeProviderProfileID
        self.lastOpenedAt = lastOpenedAt
        self.status = status
    }
}

public enum APIStyle: String, Codable, CaseIterable, Sendable {
    case openAICompatible = "openai-compatible"
    case anthropic
    case gemini
    case customJSON = "custom-json"
}

public enum AuthType: String, Codable, CaseIterable, Sendable {
    case bearer
    case header
    case query
    case none
}

public struct AuthConfiguration: Codable, Hashable, Sendable {
    public var type: AuthType
    public var keyName: String?

    public init(type: AuthType, keyName: String? = nil) {
        self.type = type
        self.keyName = keyName
    }
}

public struct ReasoningLevel: Codable, Hashable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ReasoningMapping: Codable, Hashable, Sendable {
    public var enabledField: String
    public var depthField: String
    public var levels: [ReasoningLevel]

    public init(enabledField: String, depthField: String, levels: [ReasoningLevel]) {
        self.enabledField = enabledField
        self.depthField = depthField
        self.levels = levels
    }
}

public enum CacheStrategy: String, Codable, CaseIterable, Sendable {
    case automaticPrefix = "automatic_prefix"
    case explicitCacheControl = "explicit_cache_control"
    case noProviderCacheInfo = "no_provider_cache_info"
    case disabled
}

public struct ModelProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var supportsReasoning: Bool
    public var reasoningMapping: ReasoningMapping?
    public var supportsCache: Bool
    public var cacheStrategy: CacheStrategy
    public var supportsTools: Bool
    public var supportsStreaming: Bool
    public var maxContextTokens: Int
    public var maxOutputTokens: Int
    public var extraParameters: [String: JSONValue]

    public init(id: String, displayName: String, supportsReasoning: Bool, reasoningMapping: ReasoningMapping? = nil, supportsCache: Bool, cacheStrategy: CacheStrategy, supportsTools: Bool, supportsStreaming: Bool, maxContextTokens: Int, maxOutputTokens: Int, extraParameters: [String: JSONValue] = [:]) {
        self.id = id
        self.displayName = displayName
        self.supportsReasoning = supportsReasoning
        self.reasoningMapping = reasoningMapping
        self.supportsCache = supportsCache
        self.cacheStrategy = cacheStrategy
        self.supportsTools = supportsTools
        self.supportsStreaming = supportsStreaming
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.extraParameters = extraParameters
    }
}

public struct ProviderProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var apiStyle: APIStyle
    public var baseURL: String
    public var endpoint: String
    public var auth: AuthConfiguration
    public var apiKeyReference: String?
    public var supportsStreaming: Bool
    public var supportsToolCalling: Bool
    public var supportsJSONMode: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var supportsPromptCache: Bool
    public var supportsExplicitCacheControl: Bool
    public var supportsWebSearch: Bool
    public var requestFieldMapping: [String: String]
    public var responseFieldMapping: [String: String]
    public var usageFieldMapping: [String: String]
    public var extraHeaders: [String: String]
    public var extraBodyParameters: [String: JSONValue]
    public var modelProfiles: [ModelProfile]

    public init(id: String, name: String, apiStyle: APIStyle, baseURL: String, endpoint: String, auth: AuthConfiguration, apiKeyReference: String? = nil, supportsStreaming: Bool, supportsToolCalling: Bool, supportsJSONMode: Bool, supportsVision: Bool, supportsReasoning: Bool, supportsPromptCache: Bool, supportsExplicitCacheControl: Bool, supportsWebSearch: Bool, requestFieldMapping: [String: String] = [:], responseFieldMapping: [String: String] = [:], usageFieldMapping: [String: String] = [:], extraHeaders: [String: String] = [:], extraBodyParameters: [String: JSONValue] = [:], modelProfiles: [ModelProfile]) {
        self.id = id
        self.name = name
        self.apiStyle = apiStyle
        self.baseURL = baseURL
        self.endpoint = endpoint
        self.auth = auth
        self.apiKeyReference = apiKeyReference
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalling = supportsToolCalling
        self.supportsJSONMode = supportsJSONMode
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.supportsPromptCache = supportsPromptCache
        self.supportsExplicitCacheControl = supportsExplicitCacheControl
        self.supportsWebSearch = supportsWebSearch
        self.requestFieldMapping = requestFieldMapping
        self.responseFieldMapping = responseFieldMapping
        self.usageFieldMapping = usageFieldMapping
        self.extraHeaders = extraHeaders
        self.extraBodyParameters = extraBodyParameters
        self.modelProfiles = modelProfiles
    }
}

public struct AIMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public var toolCallID: String?
    public var toolCalls: [ToolCall]?
    public var reasoningContent: String?

    public init(role: String, content: String, toolCallID: String? = nil, toolCalls: [ToolCall]? = nil, reasoningContent: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }
}

public struct ReasoningConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var level: String?

    public init(enabled: Bool, level: String? = nil) {
        self.enabled = enabled
        self.level = level
    }
}

public struct CacheHint: Codable, Hashable, Sendable {
    public var strategy: CacheStrategy
    public var prefixHash: String?

    public init(strategy: CacheStrategy, prefixHash: String? = nil) {
        self.strategy = strategy
        self.prefixHash = prefixHash
    }
}

public struct ToolCallSchema: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: JSONValue]
    public var required: [String]

    public init(name: String, description: String, parameters: [String: JSONValue], required: [String]) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
    }
}

public struct AIRequest: Codable, Hashable, Sendable {
    public var messages: [AIMessage]
    public var model: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool
    public var toolChoice: String?
    public var reasoning: ReasoningConfiguration?
    public var webSearch: JSONValue?
    public var tools: [ToolCallSchema]?
    public var cacheHint: CacheHint?
    public var extraParameters: [String: JSONValue]

    public init(messages: [AIMessage], model: String, temperature: Double? = nil, maxTokens: Int? = nil, stream: Bool, toolChoice: String? = nil, reasoning: ReasoningConfiguration? = nil, webSearch: JSONValue? = nil, tools: [ToolCallSchema]? = nil, cacheHint: CacheHint? = nil, extraParameters: [String: JSONValue] = [:]) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.toolChoice = toolChoice
        self.reasoning = reasoning
        self.webSearch = webSearch
        self.tools = tools
        self.cacheHint = cacheHint
        self.extraParameters = extraParameters
    }
}

public struct ToolCall: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var externalID: String?
    public var name: String
    public var arguments: [String: JSONValue]

    public init(id: UUID = UUID(), externalID: String? = nil, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.externalID = externalID
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentRequestOptions: Codable, Hashable, Sendable {
    public var toolChoice: String?
    public var reasoning: ReasoningConfiguration?
    public var maxTokens: Int?
    public var extraParameters: [String: JSONValue]

    public init(toolChoice: String? = "auto", reasoning: ReasoningConfiguration? = nil, maxTokens: Int? = nil, extraParameters: [String: JSONValue] = [:]) {
        self.toolChoice = toolChoice
        self.reasoning = reasoning
        self.maxTokens = maxTokens
        self.extraParameters = extraParameters
    }
}

public struct AIUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheMissInputTokens: Int?
    public var totalTokens: Int?
    public var latencyMs: Int?
    public var timeToFirstTokenMs: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, cacheMissInputTokens: Int? = nil, totalTokens: Int? = nil, latencyMs: Int? = nil, timeToFirstTokenMs: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheMissInputTokens = cacheMissInputTokens
        self.totalTokens = totalTokens
        self.latencyMs = latencyMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
    }
}

public struct AIResponse: Codable, Hashable, Sendable {
    public var text: String?
    public var toolCalls: [ToolCall]
    public var reasoningContent: String?
    public var usage: AIUsage?
    public var rawPayload: Data

    public init(text: String? = nil, toolCalls: [ToolCall] = [], reasoningContent: String? = nil, usage: AIUsage? = nil, rawPayload: Data = Data()) {
        self.text = text
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.usage = usage
        self.rawPayload = rawPayload
    }
}

public enum AgentRunStatus: String, Codable, CaseIterable, Sendable {
    case running
    case waitingForUser
    case waitingForPermission
    case waitingForPatchReview
    case completed
    case failed
    case cancelled
}

public struct PermissionDecisionRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var toolName: String
    public var permission: ToolPermission
    public var reason: String
    public var createdAt: Date

    public init(id: UUID = UUID(), toolName: String, permission: ToolPermission, reason: String, createdAt: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.permission = permission
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct AgentRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var providerID: String
    public var modelID: String
    public var userTask: String
    public var messages: [AIMessage]
    public var toolCalls: [ToolCall]
    public var toolResults: [ToolResult]
    public var usageHistory: [AIUsage]
    public var permissionDecisions: [PermissionDecisionRecord]
    public var patchProposalIDs: [UUID]
    public var status: AgentRunStatus
    public var pendingQuestion: ToolCall?
    public var pendingPermissionRequest: ToolCall?
    public var pendingPermissionDecision: PermissionDecisionRecord?
    public var finalAnswer: String?
    public var failureReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        providerID: String,
        modelID: String,
        userTask: String,
        messages: [AIMessage] = [],
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        usageHistory: [AIUsage] = [],
        permissionDecisions: [PermissionDecisionRecord] = [],
        patchProposalIDs: [UUID] = [],
        status: AgentRunStatus = .running,
        pendingQuestion: ToolCall? = nil,
        pendingPermissionRequest: ToolCall? = nil,
        pendingPermissionDecision: PermissionDecisionRecord? = nil,
        finalAnswer: String? = nil,
        failureReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.modelID = modelID
        self.userTask = userTask
        self.messages = messages
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.usageHistory = usageHistory
        self.permissionDecisions = permissionDecisions
        self.patchProposalIDs = patchProposalIDs
        self.status = status
        self.pendingQuestion = pendingQuestion
        self.pendingPermissionRequest = pendingPermissionRequest
        self.pendingPermissionDecision = pendingPermissionDecision
        self.finalAnswer = finalAnswer
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ToolPermission: String, Codable, CaseIterable, Sendable {
    case deny
    case automatic = "auto"
    case ask
    case review
    case manualOnly = "manual_only"
}

public enum GlobalPermissionMode: String, Codable, CaseIterable, Sendable {
    case manual
    case semiAuto
    case auto
}

public struct ToolPolicy: Codable, Hashable, Sendable {
    public var toolName: String
    public var permission: ToolPermission
    public var protectedPaths: [String]
    public var maxFilesWithoutConfirmation: Int
    public var maxChangedLinesWithoutConfirmation: Int
    public var requireConfirmationOnMainBranch: Bool

    public init(toolName: String, permission: ToolPermission, protectedPaths: [String] = [], maxFilesWithoutConfirmation: Int = 1, maxChangedLinesWithoutConfirmation: Int = 200, requireConfirmationOnMainBranch: Bool = true) {
        self.toolName = toolName
        self.permission = permission
        self.protectedPaths = protectedPaths
        self.maxFilesWithoutConfirmation = maxFilesWithoutConfirmation
        self.maxChangedLinesWithoutConfirmation = maxChangedLinesWithoutConfirmation
        self.requireConfirmationOnMainBranch = requireConfirmationOnMainBranch
    }
}

public struct PermissionDecision: Hashable, Sendable {
    public var permission: ToolPermission
    public var reason: String

    public init(permission: ToolPermission, reason: String) {
        self.permission = permission
        self.reason = reason
    }
}

public enum PatchOperation: String, Codable, CaseIterable, Sendable {
    case modify
    case create
    case delete
    case rename
}

public enum PatchProposalStatus: String, Codable, CaseIterable, Sendable {
    case pendingReview
    case applied
    case rejected
    case failed
    case superseded
}

public struct PatchChange: Codable, Hashable, Sendable {
    public var path: String
    public var operation: PatchOperation
    public var baseHash: String?
    public var diff: String?
    public var newPath: String?
    public var newContent: String?

    public init(path: String, operation: PatchOperation, baseHash: String? = nil, diff: String? = nil, newPath: String? = nil, newContent: String? = nil) {
        self.path = path
        self.operation = operation
        self.baseHash = baseHash
        self.diff = diff
        self.newPath = newPath
        self.newContent = newContent
    }
}

public struct PatchProposal: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var agentRunID: UUID?
    public var title: String
    public var changes: [PatchChange]
    public var reason: String
    public var createdAt: Date
    public var status: PatchProposalStatus
    public var changedFiles: Int
    public var changedLines: Int
    public var applyResult: String?
    public var errorMessage: String?
    public var snapshotID: UUID?

    public init(id: UUID = UUID(), workspaceID: UUID? = nil, agentRunID: UUID? = nil, title: String, changes: [PatchChange], reason: String, createdAt: Date = Date(), status: PatchProposalStatus = .pendingReview, changedFiles: Int? = nil, changedLines: Int? = nil, applyResult: String? = nil, errorMessage: String? = nil, snapshotID: UUID? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.agentRunID = agentRunID
        self.title = title
        self.changes = changes
        self.reason = reason
        self.createdAt = createdAt
        self.status = status
        self.changedFiles = changedFiles ?? changes.count
        self.changedLines = changedLines ?? 0
        self.applyResult = applyResult
        self.errorMessage = errorMessage
        self.snapshotID = snapshotID
    }
}

public struct SnapshotRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var createdAt: Date
    public var reason: String
    public var fileHashes: [String: String]
    public var changedFiles: [String]
    public var patchID: UUID?
    public var snapshotRootPath: String?

    public init(id: UUID = UUID(), workspaceID: UUID? = nil, createdAt: Date = Date(), reason: String, fileHashes: [String: String], changedFiles: [String], patchID: UUID? = nil, snapshotRootPath: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.reason = reason
        self.fileHashes = fileHashes
        self.changedFiles = changedFiles
        self.patchID = patchID
        self.snapshotRootPath = snapshotRootPath
    }
}

public enum ContextBlockType: String, Codable, CaseIterable, Sendable {
    case systemPrompt
    case toolSchema
    case permissionRules
    case projectRules
    case fileTree
    case repoMap
    case keyFileSummaries
    case dependencySummary
    case aiMemory
    case currentTask
    case openedFiles
    case relatedSnippets
    case currentDiff
    case ciLogs
    case userRequirements
}

public struct ContextBlock: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var type: ContextBlockType
    public var stable: Bool
    public var content: String
    public var contentHash: String
    public var tokenCount: Int
    public var order: Int
    public var lastUpdated: Date

    public init(id: UUID = UUID(), type: ContextBlockType, stable: Bool, content: String, contentHash: String, tokenCount: Int, order: Int, lastUpdated: Date = Date()) {
        self.id = id
        self.type = type
        self.stable = stable
        self.content = content
        self.contentHash = contentHash
        self.tokenCount = tokenCount
        self.order = order
        self.lastUpdated = lastUpdated
    }
}

public struct ContextSnapshot: Codable, Hashable, Sendable {
    public var blocks: [ContextBlock]
    public var prefixHash: String
    public var repoSnapshotHash: String
    public var fileTreeHash: String
    public var toolSchemaHash: String
    public var projectRulesHash: String
    public var staticTokenCount: Int
    public var dynamicTokenCount: Int
    public var includedFiles: [String]
    public var ignoredFiles: [String]

    public init(
        blocks: [ContextBlock],
        prefixHash: String,
        repoSnapshotHash: String,
        fileTreeHash: String,
        toolSchemaHash: String,
        projectRulesHash: String,
        staticTokenCount: Int,
        dynamicTokenCount: Int,
        includedFiles: [String],
        ignoredFiles: [String]
    ) {
        self.blocks = blocks
        self.prefixHash = prefixHash
        self.repoSnapshotHash = repoSnapshotHash
        self.fileTreeHash = fileTreeHash
        self.toolSchemaHash = toolSchemaHash
        self.projectRulesHash = projectRulesHash
        self.staticTokenCount = staticTokenCount
        self.dynamicTokenCount = dynamicTokenCount
        self.includedFiles = includedFiles
        self.ignoredFiles = ignoredFiles
    }
}

public enum CacheMissReason: String, Codable, CaseIterable, Sendable {
    case systemPromptChanged = "system prompt changed"
    case toolSchemaChanged = "tool schema changed"
    case providerProfileChanged = "provider profile changed"
    case modelChanged = "model changed"
    case repoMapOrderChanged = "repo map order changed"
    case projectRulesChanged = "project rules changed"
    case dynamicContentInsertedBeforeStaticPrefix = "dynamic content inserted before static prefix"
    case timestampInsertedIntoPrefix = "timestamp inserted into prefix"
    case fileTreeChanged = "file tree changed"
    case summaryRegeneratedUnstably = "key file summary regenerated with unstable wording"
    case prefixHashChanged = "prefix hash changed"
}

public struct CacheRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: String
    public var model: String
    public var apiStyle: APIStyle
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int
    public var cacheMissTokens: Int
    public var cacheHitRate: Double
    public var prefixHash: String
    public var repoSnapshotHash: String
    public var toolSchemaHash: String
    public var projectRulesHash: String
    public var fileTreeHash: String
    public var symbolIndexHash: String
    public var staticPrefixTokenCount: Int
    public var dynamicTokenCount: Int
    public var estimatedCost: Double
    public var estimatedSavedCost: Double
    public var latencyMs: Int
    public var timeToFirstTokenMs: Int
    public var cacheStrategy: CacheStrategy
    public var missReasons: [CacheMissReason]
    public var createdAt: Date

    public init(id: UUID = UUID(), provider: String, model: String, apiStyle: APIStyle, promptTokens: Int, completionTokens: Int, cachedTokens: Int, cacheMissTokens: Int, cacheHitRate: Double, prefixHash: String, repoSnapshotHash: String, toolSchemaHash: String, projectRulesHash: String, fileTreeHash: String, symbolIndexHash: String, staticPrefixTokenCount: Int, dynamicTokenCount: Int, estimatedCost: Double, estimatedSavedCost: Double, latencyMs: Int, timeToFirstTokenMs: Int, cacheStrategy: CacheStrategy, missReasons: [CacheMissReason], createdAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.model = model
        self.apiStyle = apiStyle
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.cacheMissTokens = cacheMissTokens
        self.cacheHitRate = cacheHitRate
        self.prefixHash = prefixHash
        self.repoSnapshotHash = repoSnapshotHash
        self.toolSchemaHash = toolSchemaHash
        self.projectRulesHash = projectRulesHash
        self.fileTreeHash = fileTreeHash
        self.symbolIndexHash = symbolIndexHash
        self.staticPrefixTokenCount = staticPrefixTokenCount
        self.dynamicTokenCount = dynamicTokenCount
        self.estimatedCost = estimatedCost
        self.estimatedSavedCost = estimatedSavedCost
        self.latencyMs = latencyMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.cacheStrategy = cacheStrategy
        self.missReasons = missReasons
        self.createdAt = createdAt
    }
}

public struct WorkspaceFileEntry: Codable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64

    public init(path: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct ReadFileResult: Codable, Hashable, Sendable {
    public var path: String
    public var content: String
    public var hash: String

    public init(path: String, content: String, hash: String) {
        self.path = path
        self.content = content
        self.hash = hash
    }
}

public struct SearchMatch: Codable, Hashable, Sendable {
    public var path: String
    public var lineNumber: Int
    public var line: String

    public init(path: String, lineNumber: Int, line: String) {
        self.path = path
        self.lineNumber = lineNumber
        self.line = line
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var name: String
    public var payload: JSONValue

    public init(name: String, payload: JSONValue) {
        self.name = name
        self.payload = payload
    }
}

public struct ContextStatus: Codable, Hashable, Sendable {
    public var prefixHash: String
    public var repoSnapshotHash: String
    public var staticTokenCount: Int
    public var dynamicTokenCount: Int
    public var cacheHitRate: Double?

    public init(prefixHash: String, repoSnapshotHash: String, staticTokenCount: Int, dynamicTokenCount: Int, cacheHitRate: Double? = nil) {
        self.prefixHash = prefixHash
        self.repoSnapshotHash = repoSnapshotHash
        self.staticTokenCount = staticTokenCount
        self.dynamicTokenCount = dynamicTokenCount
        self.cacheHitRate = cacheHitRate
    }
}

public struct ContextBuildRequest: Hashable, Sendable {
    public var systemPrompt: String
    public var toolSchemaText: String
    public var permissionRules: String
    public var projectRules: String
    public var dependencySummary: String
    public var aiMemory: String
    public var currentTask: String
    public var openedFiles: [ReadFileResult]
    public var relatedSnippets: [SearchMatch]
    public var currentDiff: String
    public var ciLogs: String
    public var userRequirements: String

    public init(systemPrompt: String, toolSchemaText: String, permissionRules: String, projectRules: String, dependencySummary: String, aiMemory: String, currentTask: String, openedFiles: [ReadFileResult] = [], relatedSnippets: [SearchMatch] = [], currentDiff: String = "", ciLogs: String = "", userRequirements: String) {
        self.systemPrompt = systemPrompt
        self.toolSchemaText = toolSchemaText
        self.permissionRules = permissionRules
        self.projectRules = projectRules
        self.dependencySummary = dependencySummary
        self.aiMemory = aiMemory
        self.currentTask = currentTask
        self.openedFiles = openedFiles
        self.relatedSnippets = relatedSnippets
        self.currentDiff = currentDiff
        self.ciLogs = ciLogs
        self.userRequirements = userRequirements
    }
}
