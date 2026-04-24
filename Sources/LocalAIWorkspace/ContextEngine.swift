import Foundation

public struct ContextEngine: Sendable {
    private let defaultIgnoredDirectories = [
        ".git",
        ".build",
        "DerivedData",
        "node_modules",
        "Pods",
        "vendor",
        "dist",
        "build",
        ".next",
        "__MACOSX"
    ]
    private let defaultIgnoredFiles = [".DS_Store"]

    public init() {}

    public func buildContext(using request: ContextBuildRequest, workspaceFS: WorkspaceFS) throws -> ContextSnapshot {
        let (files, ignoredFiles) = try filteredEntries(workspaceFS: workspaceFS)
        let includedFiles = files.map(\.path)
        let fileTree = includedFiles.joined(separator: "\n")
        let repoMap = files
            .filter { !$0.isDirectory }
            .map { "- \($0.path)" }
            .joined(separator: "\n")
        let keySummaries = try buildKeyFileSummaries(from: files, workspaceFS: workspaceFS)
        let toolSchemaHash = StableHasher.fnv1a64(string: request.toolSchemaText)
        let projectRulesHash = StableHasher.fnv1a64(string: request.projectRules)
        let fileTreeHash = StableHasher.fnv1a64(string: fileTree)

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
        let repoSnapshotHash = StableHasher.fnv1a64(string: fileTree + "|" + repoMap)

        return ContextSnapshot(
            blocks: contextBlocks,
            prefixHash: prefixHash,
            repoSnapshotHash: repoSnapshotHash,
            fileTreeHash: fileTreeHash,
            toolSchemaHash: toolSchemaHash,
            projectRulesHash: projectRulesHash,
            staticTokenCount: staticBlocks.reduce(0) { $0 + $1.tokenCount },
            dynamicTokenCount: dynamicBlocks.reduce(0) { $0 + $1.tokenCount },
            includedFiles: includedFiles,
            ignoredFiles: ignoredFiles
        )
    }

    private func buildKeyFileSummaries(from files: [WorkspaceFileEntry], workspaceFS: WorkspaceFS) throws -> String {
        let importantFiles = files
            .filter { !$0.isDirectory }
            .filter { entry in
                let lowercased = entry.path.lowercased()
                return lowercased.hasSuffix("readme.md") || lowercased.hasSuffix("package.swift") || lowercased.contains("settings") || lowercased.hasSuffix(".swift")
            }
            .sorted(by: { $0.path < $1.path })
            .prefix(6)

        let summaries = importantFiles.compactMap { entry -> String? in
            guard let file = try? workspaceFS.readTextFile(path: entry.path, allowProtectedPaths: true) else {
                return nil
            }
            let preview = file.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(8)
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
            return "- \(entry.path): \(preview.prefix(180))"
        }

        return summaries.joined(separator: "\n")
    }

    private func filteredEntries(workspaceFS: WorkspaceFS) throws -> ([WorkspaceFileEntry], [String]) {
        let ignoreRules = loadIgnoreRules(workspaceFS: workspaceFS)
        var ignored: [String] = []
        let entries = try workspaceFS.listFiles().sorted(by: { $0.path < $1.path }).filter { entry in
            let shouldIgnore = ignoreRules.contains { rule in
                entry.path == rule || entry.path.hasPrefix(rule + "/")
            }
            if shouldIgnore {
                ignored.append(entry.path)
            }
            return !shouldIgnore
        }
        return (entries, ignored)
    }

    private func loadIgnoreRules(workspaceFS: WorkspaceFS) -> [String] {
        var rules = defaultIgnoredDirectories + defaultIgnoredFiles
        if let ignoreFile = try? workspaceFS.readTextFile(path: ".mobiledevignore") {
            let extraRules = ignoreFile.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            rules.append(contentsOf: extraRules)
        }
        return Array(Set(rules)).sorted()
    }

    private func estimateTokens(in text: String) -> Int {
        max(1, text.split { $0.isWhitespace || $0.isNewline }.count)
    }
}
