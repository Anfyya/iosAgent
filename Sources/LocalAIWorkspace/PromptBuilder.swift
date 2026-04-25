import Foundation

public struct PromptBuilder: Sendable {
    public init() {}

    public func build(
        snapshot: ContextSnapshot,
        userTask: String,
        toolSchemas: [ToolCallSchema],
        permissionRules: String,
        activeProvider: ProviderProfile,
        activeModel: ModelProfile,
        workspace: Workspace,
        additionalUserRequirements: String = ""
    ) -> PromptBuildOutput {
        let resolvedModelName = activeModel.displayName.isEmpty ? activeModel.id : activeModel.displayName
        let workspaceMetadata = [
            "workspace=\(workspace.name)",
            "branch=\(workspace.currentBranch ?? "local")",
            "provider=\(activeProvider.name)",
            "model=\(resolvedModelName)",
            "prefixHash=\(snapshot.prefixHash)"
        ].joined(separator: " ")
        let systemMessage = [
            "You are a local-first engineering workspace assistant.",
            "Security rules:",
            "- Do not modify files the user did not request.",
            "- If requirements are ambiguous or out of scope, call ask_question before proceeding.",
            "- Do not write files directly; only use propose_patch.",
            "- Deletions, renames, GitHub sync, and Actions operations require confirmation.",
            "- Never read keychain values, API keys, or secrets.",
            "- Never access paths outside workspace/files.",
            "Tool usage:",
            "- Prefer list_files/read_file/search_in_files/get_context_status before proposing changes.",
            "- When the user asks to change files, use propose_patch with concrete file changes; do not only describe what should change.",
            "- ask_question must be blocking when clarification is required.",
            "- propose_patch must include a precise title, reason, and concrete file changes.",
            "Patch format:",
            "- Only describe file changes the user explicitly asked for.",
            "- Use unified diff for modify operations and explicit create/delete/rename metadata when needed.",
            "Ask-question rules:",
            "- Use ask_question whenever scope, target file, desired output, or risky actions are uncertain."
        ].joined(separator: "\n")

        let stablePrefix = [
            "[STATIC PREFIX START]",
            labeled("system rules", content: snapshot.blocks.first(where: { $0.type == .systemPrompt })?.content ?? ""),
            labeled("tool schema text", content: renderSchemas(toolSchemas)),
            labeled("permission rules", content: permissionRules),
            labeled("project rules", content: snapshot.blocks.first(where: { $0.type == .projectRules })?.content ?? ""),
            labeled("stable file tree", content: snapshot.blocks.first(where: { $0.type == .fileTree })?.content ?? ""),
            labeled("repo map", content: snapshot.blocks.first(where: { $0.type == .repoMap })?.content ?? ""),
            labeled("key file summaries", content: snapshot.blocks.first(where: { $0.type == .keyFileSummaries })?.content ?? ""),
            labeled("dependency summary", content: snapshot.blocks.first(where: { $0.type == .dependencySummary })?.content ?? ""),
            labeled("ai memory", content: snapshot.blocks.first(where: { $0.type == .aiMemory })?.content ?? ""),
            labeled("workspace metadata", content: workspaceMetadata),
            "[STATIC PREFIX END]"
        ]
        .filter { $0.isEmpty == false }
        .joined(separator: "\n\n")

        let dynamicTask = [
            "[DYNAMIC TASK START]",
            labeled("current task", content: userTask),
            labeled("opened files", content: snapshot.blocks.first(where: { $0.type == .openedFiles })?.content ?? ""),
            labeled("related snippets", content: snapshot.blocks.first(where: { $0.type == .relatedSnippets })?.content ?? ""),
            labeled("current diff", content: snapshot.blocks.first(where: { $0.type == .currentDiff })?.content ?? ""),
            labeled("ci logs", content: snapshot.blocks.first(where: { $0.type == .ciLogs })?.content ?? ""),
            labeled("user requirements", content: [snapshot.blocks.first(where: { $0.type == .userRequirements })?.content ?? "", additionalUserRequirements].filter { $0.isEmpty == false }.joined(separator: "\n")),
            "[DYNAMIC TASK END]"
        ]
        .filter { $0.isEmpty == false }
        .joined(separator: "\n\n")

        let contextMessage = [stablePrefix, dynamicTask].filter { $0.isEmpty == false }.joined(separator: "\n\n")
        return PromptBuildOutput(
            systemMessage: systemMessage,
            contextMessage: contextMessage,
            messages: [
                AIMessage(role: "system", content: systemMessage),
                AIMessage(role: "user", content: contextMessage)
            ]
        )
    }

    private func renderSchemas(_ schemas: [ToolCallSchema]) -> String {
        schemas.sorted(by: { $0.name < $1.name }).map { schema in
            let required = schema.required.sorted().joined(separator: ", ")
            return "- \(schema.name): \(schema.description) | required: [\(required)]"
        }.joined(separator: "\n")
    }

    private func labeled(_ label: String, content: String) -> String {
        guard content.isEmpty == false else { return "" }
        return "[\(label)]\n\(content)"
    }
}
