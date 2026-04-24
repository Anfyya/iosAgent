import Foundation

public enum SupportedTools {
    public static let schemas: [ToolCallSchema] = [
        ToolCallSchema(
            name: "list_files",
            description: "List files inside the current workspace.",
            parameters: [:],
            required: []
        ),
        ToolCallSchema(
            name: "read_file",
            description: "Read a text file in the current workspace and return its content plus hash.",
            parameters: ["path": .object(["type": .string("string")])],
            required: ["path"]
        ),
        ToolCallSchema(
            name: "search_in_files",
            description: "Search workspace text files.",
            parameters: ["query": .object(["type": .string("string")])],
            required: ["query"]
        ),
        ToolCallSchema(
            name: "ask_question",
            description: "Ask the user a clarification question before taking action.",
            parameters: [
                "question": .object(["type": .string("string")]),
                "reason": .object(["type": .string("string")]),
                "options": .object(["type": .string("array")]),
                "blocking": .object(["type": .string("boolean")])
            ],
            required: ["question", "reason", "blocking"]
        ),
        ToolCallSchema(
            name: "propose_patch",
            description: "Submit a patch proposal for review instead of writing files directly.",
            parameters: [
                "title": .object(["type": .string("string")]),
                "reason": .object(["type": .string("string")]),
                "changes": .object(["type": .string("array")])
            ],
            required: ["title", "reason", "changes"]
        ),
        ToolCallSchema(
            name: "get_context_status",
            description: "Get prefix hash, repo snapshot hash, and cache status for the current workspace.",
            parameters: [:],
            required: []
        )
    ]
}

public enum ToolExecutionError: Error {
    case missingArgument(String)
    case unsupportedTool(String)
    case malformedPayload(String)
}

public struct ToolExecutor: Sendable {
    public let workspaceFS: WorkspaceFS
    public let contextEngine: ContextEngine
    public let patchStore: PatchStore?

    public init(workspaceFS: WorkspaceFS, contextEngine: ContextEngine, patchStore: PatchStore? = nil) {
        self.workspaceFS = workspaceFS
        self.contextEngine = contextEngine
        self.patchStore = patchStore
    }

    public func execute(_ call: ToolCall, workspaceID: UUID? = nil, agentRunID: UUID? = nil, contextRequest: ContextBuildRequest? = nil) throws -> ToolResult {
        switch call.name {
        case "list_files":
            let files = try workspaceFS.listFiles().map { entry in
                JSONValue.object([
                    "path": .string(entry.path),
                    "isDirectory": .bool(entry.isDirectory),
                    "size": .integer(Int(entry.size))
                ])
            }
            return ToolResult(name: call.name, payload: .array(files))

        case "read_file":
            let path = try stringArgument(named: "path", in: call.arguments)
            let file = try workspaceFS.readTextFile(path: path)
            return ToolResult(name: call.name, payload: .object([
                "path": .string(file.path),
                "content": .string(file.content),
                "hash": .string(file.hash)
            ]))

        case "search_in_files":
            let query = try stringArgument(named: "query", in: call.arguments)
            let matches = try workspaceFS.search(query: query).map { match in
                JSONValue.object([
                    "path": .string(match.path),
                    "lineNumber": .integer(match.lineNumber),
                    "line": .string(match.line)
                ])
            }
            return ToolResult(name: call.name, payload: .array(matches))

        case "ask_question":
            return ToolResult(name: call.name, payload: .object(call.arguments))

        case "propose_patch":
            let title = try stringArgument(named: "title", in: call.arguments)
            let reason = try stringArgument(named: "reason", in: call.arguments)
            let changes = try Self.decodePatchChanges(from: call.arguments["changes"])
            let impact = ToolImpactAnalyzer.estimate(call)
            let proposal = PatchProposal(
                workspaceID: workspaceID,
                agentRunID: agentRunID,
                title: title,
                changes: changes,
                reason: reason,
                status: .pendingReview,
                changedFiles: max(changes.count, impact.changedFiles),
                changedLines: impact.changedLines
            )
            try patchStore?.save(proposal)
            return ToolResult(name: call.name, payload: .object([
                "queued": .bool(true),
                "proposalId": .string(proposal.id.uuidString),
                "changeCount": .integer(proposal.changes.count),
                "changedFiles": .integer(proposal.changedFiles),
                "changedLines": .integer(proposal.changedLines)
            ]))

        case "get_context_status":
            guard let contextRequest else {
                throw ToolExecutionError.malformedPayload("Context request is required for context status.")
            }
            let snapshot = try contextEngine.buildContext(using: contextRequest, workspaceFS: workspaceFS)
            return ToolResult(name: call.name, payload: .object([
                "prefixHash": .string(snapshot.prefixHash),
                "repoSnapshotHash": .string(snapshot.repoSnapshotHash),
                "staticTokenCount": .integer(snapshot.staticTokenCount),
                "dynamicTokenCount": .integer(snapshot.dynamicTokenCount)
            ]))

        default:
            throw ToolExecutionError.unsupportedTool(call.name)
        }
    }

    private func stringArgument(named name: String, in arguments: [String: JSONValue]) throws -> String {
        guard case let .string(value)? = arguments[name] else {
            throw ToolExecutionError.missingArgument(name)
        }
        return value
    }

    public static func decodePatchChanges(from value: JSONValue?) throws -> [PatchChange] {
        guard case let .array(items)? = value else {
            throw ToolExecutionError.malformedPayload("changes must be an array")
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return try items.map { item in
            let data = try encoder.encode(item)
            return try decoder.decode(PatchChange.self, from: data)
        }
    }

}
