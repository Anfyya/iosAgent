import Foundation

public struct ContextEngine: Sendable {
    public init() {}

    public func buildContext(using request: ContextBuildRequest, workspaceFS: WorkspaceFS) throws -> ContextSnapshot {
        let files = try workspaceFS.listFiles()
        let fileTree = files.map(\.path).joined(separator: "\n")
        let repoMap = files
            .filter { !$0.isDirectory }
            .map { "- \($0.path)" }
            .joined(separator: "\n")
        let keySummaries = try buildKeyFileSummaries(from: files, workspaceFS: workspaceFS)

        let blocks: [(ContextBlockType, Bool, String)] = [
            (.systemPrompt, true, request.systemPrompt),
            (.toolSchema, true, request.toolSchemaText),
            (.permissionRules, true, request.permissionRules),
            (.projectRules, true, request.projectRules),
            (.fileTree, true, fileTree),
            (.repoMap, true, repoMap),
            (.keyFileSummaries, true, keySummaries),
            (.dependencySummary, true, request.dependencySummary),
            (.aiMemory, true, request.aiMemory),
            (.currentTask, false, request.currentTask),
            (.openedFiles, false, request.openedFiles.map { "# \($0.path)\n\($0.content)" }.joined(separator: "\n\n")),
            (.relatedSnippets, false, request.relatedSnippets.map { "\($0.path):\($0.lineNumber)\n\($0.line)" }.joined(separator: "\n\n")),
            (.currentDiff, false, request.currentDiff),
            (.ciLogs, false, request.ciLogs),
            (.userRequirements, false, request.userRequirements)
        ]

        let contextBlocks = blocks.enumerated().map { index, block in
            let tokenCount = estimateTokens(in: block.2)
            return ContextBlock(
                type: block.0,
                stable: block.1,
                content: block.2,
                contentHash: StableHasher.fnv1a64(string: block.2),
                tokenCount: tokenCount,
                order: index
            )
        }

        let staticBlocks = contextBlocks.filter(\.stable)
        let dynamicBlocks = contextBlocks.filter { !$0.stable }
        let prefixHash = StableHasher.fnv1a64(string: staticBlocks.map(\.contentHash).joined(separator: "|"))
        let repoSnapshotHash = StableHasher.fnv1a64(string: fileTree + repoMap)

        return ContextSnapshot(
            blocks: contextBlocks,
            prefixHash: prefixHash,
            repoSnapshotHash: repoSnapshotHash,
            staticTokenCount: staticBlocks.reduce(0) { $0 + $1.tokenCount },
            dynamicTokenCount: dynamicBlocks.reduce(0) { $0 + $1.tokenCount }
        )
    }

    private func buildKeyFileSummaries(from files: [WorkspaceFileEntry], workspaceFS: WorkspaceFS) throws -> String {
        let importantFiles = files
            .filter { !$0.isDirectory }
            .filter { entry in
                let lowercased = entry.path.lowercased()
                return lowercased.hasSuffix("readme.md") || lowercased.hasSuffix("package.swift") || lowercased.contains("settings") || lowercased.hasSuffix(".swift")
            }
            .prefix(6)

        let summaries = try importantFiles.map { entry -> String in
            let file = try workspaceFS.readTextFile(path: entry.path, allowProtectedPaths: true)
            let preview = file.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(8)
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
            return "- \(entry.path): \(preview.prefix(180))"
        }

        return summaries.joined(separator: "\n")
    }

    private func estimateTokens(in text: String) -> Int {
        max(1, text.split { $0.isWhitespace || $0.isNewline }.count)
    }
}
