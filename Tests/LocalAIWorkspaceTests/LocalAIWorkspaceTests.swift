import Foundation
import Testing
@testable import LocalAIWorkspace

struct WorkspaceFSTests {
    @Test func safeURLRejectsTraversal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try WorkspaceFS(rootURL: root)

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.safeURL(for: "../Secrets.txt")
        }
    }

    @Test func readAndSearchTextFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try WorkspaceFS(rootURL: root)
        try fs.writeTextFile(path: "Sources/App.swift", content: "let title = \"ContextPilot\"\n")

        let file = try fs.readTextFile(path: "Sources/App.swift")
        let matches = try fs.search(query: "ContextPilot")

        #expect(file.hash.isEmpty == false)
        #expect(matches.count == 1)
        #expect(matches.first?.lineNumber == 1)
    }
}

struct PermissionManagerTests {
    @Test func workflowChangesAlwaysAsk() async throws {
        let manager = PermissionManager(globalMode: .auto)
        let call = ToolCall(name: "propose_patch", arguments: ["path": .string(".github/workflows/build-ios.yml")])

        let decision = manager.decide(for: call)
        #expect(decision.permission == .ask)
    }
}

struct PatchEngineTests {
    @Test func appliesUnifiedDiffAndCreatesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try WorkspaceFS(rootURL: root)
        try fs.writeTextFile(path: "Sources/App/LoginView.swift", content: "Button(\"Login\") {\n    login()\n}\n")
        let base = try fs.readTextFile(path: "Sources/App/LoginView.swift", allowProtectedPaths: true)

        let proposal = PatchProposal(
            title: "Prevent repeat login",
            changes: [
                PatchChange(
                    path: "Sources/App/LoginView.swift",
                    operation: .modify,
                    baseHash: base.hash,
                    diff: "@@ -1,3 +1,5 @@\n Button(\"Login\") {\n+    guard !isLoading else { return }\n+    isLoading = true\n     login()\n }"
                )
            ],
            reason: "Prevent duplicate login requests."
        )

        let result = try PatchEngine().apply(proposal: proposal, workspaceFS: fs)
        let updated = try fs.readTextFile(path: "Sources/App/LoginView.swift", allowProtectedPaths: true)

        #expect(updated.content.contains("guard !isLoading else { return }"))
        #expect(result.snapshot.changedFiles.contains("Sources/App/LoginView.swift"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mobiledev/snapshots").path))
    }
}

struct ContextAndCacheTests {
    @Test func contextPlacesStableBlocksFirstAndTracksCacheMisses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try WorkspaceFS(rootURL: root)
        try fs.writeTextFile(path: "README.md", content: "# RepoGlass\n")

        let request = ContextBuildRequest(
            systemPrompt: "system",
            toolSchemaText: "tools",
            permissionRules: "permissions",
            projectRules: "rules",
            dependencySummary: "swiftui, swiftdata",
            aiMemory: "remember stable ordering",
            currentTask: "Build the MVP shell",
            userRequirements: "Do not modify files beyond scope."
        )

        let contextEngine = ContextEngine()
        let snapshot = try contextEngine.buildContext(using: request, workspaceFS: fs)
        let previous = CacheRecord(
            provider: "Old Provider",
            model: "old-model",
            apiStyle: .openAICompatible,
            promptTokens: 10,
            completionTokens: 1,
            cachedTokens: 0,
            cacheMissTokens: 10,
            cacheHitRate: 0,
            prefixHash: "old-prefix",
            repoSnapshotHash: "old-repo",
            toolSchemaHash: "old-tool",
            projectRulesHash: "old-rules",
            fileTreeHash: "old-tree",
            symbolIndexHash: "old-symbols",
            staticPrefixTokenCount: 1,
            dynamicTokenCount: 1,
            estimatedCost: 0,
            estimatedSavedCost: 0,
            latencyMs: 0,
            timeToFirstTokenMs: 0,
            cacheStrategy: .automaticPrefix,
            missReasons: []
        )

        let record = CacheEngine().makeRecord(
            provider: MVPSampleData.defaultProvider,
            model: MVPSampleData.defaultProvider.modelProfiles[0],
            snapshot: snapshot,
            usage: AIUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 80, cacheMissInputTokens: 20),
            previous: previous
        )

        #expect(snapshot.blocks.prefix(3).allSatisfy { $0.stable })
        #expect(record.cacheHitRate == 0.8)
        #expect(record.missReasons.contains(.providerProfileChanged))
        #expect(record.missReasons.contains(.modelChanged))
    }
}
