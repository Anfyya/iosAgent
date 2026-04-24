import Foundation

public protocol AgentRunStore: Sendable {
    func save(_ run: AgentRun) throws
    func run(id: UUID) throws -> AgentRun?
}

public struct FileAgentRunStore: AgentRunStore {
    public let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func save(_ run: AgentRun) throws {
        var runs = try load()
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(runs.sorted(by: { $0.updatedAt < $1.updatedAt }))
        try data.write(to: storageURL, options: .atomic)
    }

    public func run(id: UUID) throws -> AgentRun? {
        try load().first(where: { $0.id == id })
    }

    private func load() throws -> [AgentRun] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        return try JSONDecoder().decode([AgentRun].self, from: Data(contentsOf: storageURL))
    }
}

public final class InMemoryAgentRunStore: AgentRunStore, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [UUID: AgentRun] = [:]

    public init() {}

    public func save(_ run: AgentRun) throws {
        lock.lock()
        defer { lock.unlock() }
        runs[run.id] = run
    }

    public func run(id: UUID) throws -> AgentRun? {
        lock.lock()
        defer { lock.unlock() }
        return runs[id]
    }
}

public enum AgentLoopError: Error, LocalizedError {
    case maxRoundsExceeded(Int)
    case missingRun(UUID)
    case missingPendingQuestion(UUID)
    case missingPendingPermissionRequest(UUID)

    public var errorDescription: String? {
        switch self {
        case let .maxRoundsExceeded(limit):
            return "Agent loop exceeded the maximum of \(limit) tool rounds."
        case let .missingRun(id):
            return "Agent run not found: \(id.uuidString)"
        case let .missingPendingQuestion(id):
            return "Agent run \(id.uuidString) is not waiting for a user answer."
        case let .missingPendingPermissionRequest(id):
            return "Agent run \(id.uuidString) is not waiting for a permission decision."
        }
    }
}

public struct AgentLoop: Sendable {
    public let client: AIClient
    public let patchStore: PatchStore
    public let runStore: AgentRunStore
    public let toolExecutor: ToolExecutor
    public let permissionManager: PermissionManager
    public let maxRounds: Int

    public init(
        client: AIClient,
        patchStore: PatchStore,
        runStore: AgentRunStore,
        toolExecutor: ToolExecutor,
        permissionManager: PermissionManager,
        maxRounds: Int = 8
    ) {
        self.client = client
        self.patchStore = patchStore
        self.runStore = runStore
        self.toolExecutor = toolExecutor
        self.permissionManager = permissionManager
        self.maxRounds = maxRounds
    }

    public func start(
        workspaceID: UUID,
        profile: ProviderProfile,
        apiKey: String?,
        modelID: String,
        systemPrompt: String,
        userTask: String,
        contextRequest: ContextBuildRequest? = nil
    ) async throws -> AgentRun {
        var run = AgentRun(
            workspaceID: workspaceID,
            providerID: profile.id,
            modelID: modelID,
            userTask: userTask,
            messages: [
                AIMessage(role: "system", content: systemPrompt),
                AIMessage(role: "user", content: userTask)
            ]
        )
        try save(&run)
        return try await continueRun(run: run, profile: profile, apiKey: apiKey, contextRequest: contextRequest)
    }

    public func resume(runID: UUID, answer: String, profile: ProviderProfile, apiKey: String?, contextRequest: ContextBuildRequest? = nil) async throws -> AgentRun {
        guard var run = try runStore.run(id: runID) else {
            throw AgentLoopError.missingRun(runID)
        }
        guard let question = run.pendingQuestion else {
            throw AgentLoopError.missingPendingQuestion(runID)
        }

        let answerResult = ToolResult(
            name: question.name,
            payload: .object([
                "question": question.arguments["question"] ?? .null,
                "answer": .string(answer),
                "blocking": question.arguments["blocking"] ?? .bool(true)
            ])
        )
        run.pendingQuestion = nil
        run.status = .running
        run.toolResults.append(answerResult)
        run.messages.append(AIMessage(role: "tool", content: jsonString(from: answerResult.payload)))
        run.messages.append(AIMessage(role: "user", content: answer))
        try save(&run)

        return try await continueRun(run: run, profile: profile, apiKey: apiKey, contextRequest: contextRequest)
    }

    public func resumePermission(
        runID: UUID,
        approved: Bool,
        profile: ProviderProfile,
        apiKey: String?,
        contextRequest: ContextBuildRequest? = nil
    ) async throws -> AgentRun {
        guard var run = try runStore.run(id: runID) else {
            throw AgentLoopError.missingRun(runID)
        }
        guard let pendingCall = run.pendingPermissionRequest else {
            throw AgentLoopError.missingPendingPermissionRequest(runID)
        }

        let decision = run.pendingPermissionDecision
        run.pendingPermissionRequest = nil
        run.pendingPermissionDecision = nil
        run.status = .running

        let result: ToolResult
        if approved {
            result = try toolExecutor.execute(
                pendingCall,
                workspaceID: run.workspaceID,
                agentRunID: run.id,
                contextRequest: contextRequest
            )
            if pendingCall.name == "propose_patch",
               case let .string(id)? = result.payload.objectValue?["proposalId"],
               let proposalID = UUID(uuidString: id) {
                run.patchProposalIDs.append(proposalID)
            }
        } else {
            result = ToolResult(
                name: pendingCall.name,
                payload: .object([
                    "denied": .bool(true),
                    "reason": .string(decision?.reason ?? "User denied permission.")
                ])
            )
        }

        run.toolResults.append(result)
        run.messages.append(AIMessage(role: "tool", content: jsonString(from: result.payload)))
        try save(&run)
        return try await continueRun(run: run, profile: profile, apiKey: apiKey, contextRequest: contextRequest)
    }

    private func continueRun(run initialRun: AgentRun, profile: ProviderProfile, apiKey: String?, contextRequest: ContextBuildRequest?) async throws -> AgentRun {
        var run = initialRun
        var rounds = 0

        // The loop exits only when the model returns a final answer, the run transitions
        // into a waiting state, or maxRounds is exceeded and an error is thrown.
        while true {
            if rounds >= maxRounds {
                run.status = .failed
                run.failureReason = AgentLoopError.maxRoundsExceeded(maxRounds).localizedDescription
                try save(&run)
                throw AgentLoopError.maxRoundsExceeded(maxRounds)
            }

            let request = AIRequest(
                messages: run.messages,
                model: run.modelID,
                stream: false,
                tools: SupportedTools.schemas
            )
            let response = try await client.complete(profile: profile, apiKey: apiKey, request: request)
            if let usage = response.usage {
                run.usageHistory.append(usage)
            }

            if let text = response.text, response.toolCalls.isEmpty {
                run.messages.append(AIMessage(role: "assistant", content: text))
                run.finalAnswer = text
                run.status = .completed
                try save(&run)
                return run
            }

            rounds += 1
            for call in response.toolCalls {
                run.toolCalls.append(call)
                if call.name == "ask_question",
                   case let .bool(blocking)? = call.arguments["blocking"],
                   blocking {
                    run.pendingQuestion = call
                    run.status = .waitingForUser
                    try save(&run)
                    return run
                }

                let impact = ToolImpactAnalyzer.estimate(call)
                let decision = permissionManager.decide(for: call, impact: impact)
                let record = PermissionDecisionRecord(toolName: call.name, permission: decision.permission, reason: decision.reason)
                run.permissionDecisions.append(record)

                if decision.permission == .deny {
                    let denied = ToolResult(
                        name: call.name,
                        payload: .object([
                            "denied": .bool(true),
                            "reason": .string(decision.reason)
                        ])
                    )
                    run.toolResults.append(denied)
                    run.messages.append(AIMessage(role: "tool", content: jsonString(from: denied.payload)))
                    continue
                }

                if decision.permission == .ask {
                    run.pendingPermissionRequest = call
                    run.pendingPermissionDecision = record
                    run.status = .waitingForPermission
                    try save(&run)
                    return run
                }

                let result = try toolExecutor.execute(
                    call,
                    workspaceID: run.workspaceID,
                    agentRunID: run.id,
                    contextRequest: contextRequest
                )
                run.toolResults.append(result)
                if call.name == "propose_patch",
                   case let .string(id)? = result.payload.objectValue?["proposalId"],
                   let proposalID = UUID(uuidString: id) {
                    run.patchProposalIDs.append(proposalID)
                }
                run.messages.append(AIMessage(role: "tool", content: jsonString(from: result.payload)))

                if decision.permission == .review, call.name == "propose_patch" {
                    run.status = .waitingForPatchReview
                    try save(&run)
                    return run
                }
            }

            try save(&run)
        }
    }

    private func save(_ run: inout AgentRun) throws {
        run.updatedAt = .now
        try runStore.save(run)
    }

    private func jsonString(from value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fallback = #"{"encoding_error":true,"payload_kind":"json_value"}"#
        let data = (try? encoder.encode(value)) ?? Data(fallback.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}
