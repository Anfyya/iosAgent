import Foundation
import Testing
@testable import LocalAIWorkspace

struct WorkspaceFSTests {
    @Test func safeURLRejectsTraversal() async throws {
        let fs = try makeWorkspaceFS()

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.safeURL(for: "../Secrets.txt")
        }
    }

    @Test func safeURLRejectsAbsolutePaths() async throws {
        let fs = try makeWorkspaceFS()

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.safeURL(for: "/tmp/secret.txt")
        }
    }

    @Test func safeURLRejectsCurrentDirectoryAlias() async throws {
        let fs = try makeWorkspaceFS()

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.writeTextFile(path: ".", content: "bad")
        }
    }

    @Test func safeURLRejectsSymlinkEscape() async throws {
        let root = makeTemporaryDirectory()
        let sibling = makeTemporaryDirectory()
        try "secret".data(using: .utf8)?.write(to: sibling.appendingPathComponent("secret.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("links"), withIntermediateDirectories: true)
        #if os(macOS) || os(Linux)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("links/outside"),
            withDestinationURL: sibling
        )
        #endif
        let fs = try WorkspaceFS(rootURL: root)

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.readTextFile(path: "links/outside/secret.txt")
        }
    }

    @Test func protectedPathsAndInlineLimitsAreEnforced() async throws {
        let root = makeTemporaryDirectory()
        let fs = try WorkspaceFS(rootURL: root, maxInlineFileSize: 8, protectedPathPrefixes: [".mobiledev/cache"])
        try fs.writeTextFile(path: ".mobiledev/cache/state.json", content: "{}", allowProtectedPaths: true)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
        try fs.writeTextFile(path: "large.txt", content: "0123456789")

        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.readTextFile(path: ".mobiledev/cache/state.json")
        }
        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.readTextFile(path: "blob.bin")
        }
        #expect(throws: WorkspaceFSError.self) {
            _ = try fs.readTextFile(path: "large.txt")
        }
    }

    @Test func readAndSearchTextFiles() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "Sources/App.swift", content: "let title = \"ContextPilot\"\n")

        let file = try fs.readTextFile(path: "Sources/App.swift")
        let matches = try fs.search(query: "ContextPilot")

        #expect(file.hash.isEmpty == false)
        #expect(matches.count == 1)
        #expect(matches.first?.lineNumber == 1)
    }

    @Test func safeURLAcceptsRootReachedThroughSymlinkAlias() async throws {
        #if os(macOS) || os(Linux)
        let realRoot = makeTemporaryDirectory()
        let aliasParent = makeTemporaryDirectory()
        let aliasRoot = aliasParent.appendingPathComponent("workspace-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        let fs = try WorkspaceFS(rootURL: aliasRoot)

        try fs.writeTextFile(path: "Sources/NewFile.swift", content: "let ok = true\n")

        let created = realRoot.appendingPathComponent("Sources/NewFile.swift")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #endif
    }
}

struct PermissionManagerTests {
    @Test func workflowChangesAlwaysAsk() async throws {
        let manager = PermissionManager(globalMode: .auto)
        let call = ToolCall(name: "propose_patch", arguments: ["path": .string(".github/workflows/build-ios.yml")])

        let decision = manager.decide(for: call)
        #expect(decision.permission == .ask)
    }

    @Test func toolImpactAnalyzerTracksProtectedAndDestructiveChanges() async throws {
        let call = ToolCall(name: "propose_patch", arguments: [
            "changes": .array([
                .object([
                    "path": .string(".mobiledev/cache/state.json"),
                    "operation": .string("delete")
                ])
            ])
        ])

        let impact = ToolImpactAnalyzer.estimate(call)

        #expect(impact.touchesProtectedPath)
        #expect(impact.isDestructive)
        #expect(impact.changedFiles == 1)
    }
}

struct ProviderAdapterTests {
    @Test func buildsOpenAICompatibleRequestBody() async throws {
        let profile = makeProviderProfile()
        let request = AIRequest(
            messages: [AIMessage(role: "user", content: "hello")],
            model: "deepseek-v4-pro",
            temperature: 0.2,
            maxTokens: 256,
            stream: false,
            toolChoice: "auto",
            reasoning: ReasoningConfiguration(enabled: true, level: "high"),
            webSearch: .object(["enabled": .bool(true)]),
            tools: SupportedTools.schemas,
            extraParameters: ["metadata.trace": .string("abc123")]
        )

        let body = try OpenAICompatibleAdapter().buildRequestBody(profile: profile, request: request)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect((json["temperature"] as? Double) == 0.2)
        #expect((json["max_tokens"] as? Int) == 256)
        #expect((json["enable_thinking"] as? Bool) == true)
        #expect((json["thinking_level"] as? String) == "high")
        #expect((json["tools"] as? [[String: Any]])?.isEmpty == false)
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect((metadata["trace"] as? String) == "abc123")
        let webSearch = try #require(json["web_search"] as? [String: Any])
        #expect((webSearch["enabled"] as? Bool) == true)
    }

    @Test func buildsURLRequestWithHeadersAndBodyMappings() async throws {
        var profile = makeProviderProfile()
        profile.auth = AuthConfiguration(type: .header, keyName: "x-api-key")
        profile.extraHeaders = ["X-Trace": "trace-1"]
        let request = AIRequest(messages: [AIMessage(role: "user", content: "hi")], model: "deepseek-v4-pro", stream: false)

        let urlRequest = try OpenAICompatibleAIClient().buildURLRequest(profile: profile, apiKey: "secret", request: request)

        #expect(urlRequest.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Trace") == "trace-1")
    }

    @Test func buildsStreamingURLRequestWithTools() async throws {
        let profile = makeProviderProfile()
        let request = AIRequest(
            messages: [AIMessage(role: "user", content: "use tools")],
            model: "deepseek-v4-pro",
            stream: true,
            toolChoice: "auto",
            tools: SupportedTools.schemas
        )

        let urlRequest = try OpenAICompatibleAIClient().buildURLRequest(profile: profile, apiKey: "secret", request: request)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["stream"] as? Bool == true)
        #expect((json["tools"] as? [[String: Any]])?.isEmpty == false)
        #expect(json["tool_choice"] as? String == "auto")
    }

    @Test func parsesUsageToolCallsAndErrorFallbacks() async throws {
        let profile = makeProviderProfile()
        let payload = """
        {
          "choices": [
            {
              "message": {
                "content": "done",
                "reasoning_content": "checked",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "read_file",
                      "arguments": "{\\"path\\":\\"README.md\\"}"
                    }
                  }
                ]
              }
            }
          ],
          "usage": {
            "prompt_tokens": 12,
            "completion_tokens": 4,
            "total_tokens": 16,
            "prompt_tokens_details": {
              "cached_tokens": 8
            },
            "prompt_cache_miss_tokens": 4
          }
        }
        """.data(using: .utf8)!

        let response = try OpenAICompatibleAdapter().parseResponse(profile: profile, data: payload)
        let usage = try #require(response.usage)

        #expect(response.text == "done")
        #expect(response.reasoningContent == "checked")
        #expect(response.toolCalls.first?.name == "read_file")
        #expect(response.toolCalls.first?.arguments["path"] == .string("README.md"))
        #expect(usage.inputTokens == 12)
        #expect(usage.cachedInputTokens == 8)
        #expect(usage.cacheMissInputTokens == 4)

        let errorPayload = #"{"error":{"message":"bad request"}}"#.data(using: .utf8)!
        #expect(ProviderPayloadParser.errorMessage(from: errorPayload, profile: profile) == "bad request")
    }
}

struct PatchEngineTests {
    @Test func appliesUnifiedDiffAndCreatesSnapshot() async throws {
        let root = makeTemporaryDirectory()
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
        #expect(FileManager.default.fileExists(atPath: try #require(result.snapshot.snapshotRootPath)))
    }

    @Test func protectedPathRequiresConfirmation() async throws {
        let root = makeTemporaryDirectory()
        let fs = try WorkspaceFS(rootURL: root, protectedPathPrefixes: [".mobiledev/cache"])
        try fs.writeTextFile(path: ".mobiledev/cache/state.json", content: "{}", allowProtectedPaths: true)

        let proposal = PatchProposal(
            title: "Change protected cache",
            changes: [
                PatchChange(path: ".mobiledev/cache/state.json", operation: .modify, baseHash: try fs.hashForFile(at: ".mobiledev/cache/state.json", allowProtectedPaths: true), diff: "@@ -1 +1 @@\n-{}\n+{\"ok\":true}")
            ],
            reason: "test"
        )

        #expect(throws: PatchEngineError.self) {
            _ = try PatchEngine().apply(proposal: proposal, workspaceFS: fs)
        }
    }

    @Test func restoresSnapshot() async throws {
        let root = makeTemporaryDirectory()
        let fs = try WorkspaceFS(rootURL: root)
        try fs.writeTextFile(path: "README.md", content: "before\n")
        let base = try fs.readTextFile(path: "README.md")
        let proposal = PatchProposal(
            title: "Update README",
            changes: [PatchChange(path: "README.md", operation: .modify, baseHash: base.hash, diff: "@@ -1 +1 @@\n-before\n+after")],
            reason: "restore test"
        )

        let result = try PatchEngine().apply(proposal: proposal, workspaceFS: fs)
        try PatchEngine().restore(snapshot: result.snapshot, workspaceFS: fs)

        #expect(try fs.readTextFile(path: "README.md").content == "before\n")
    }
}

struct ContextAndCacheTests {
    @Test func contextPlacesStableBlocksFirstAndTracksCacheMisses() async throws {
        let fs = try makeWorkspaceFS()
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

        let provider = makeProviderProfile()
        let record = CacheEngine().makeRecord(
            provider: provider,
            model: provider.modelProfiles[0],
            snapshot: snapshot,
            usage: AIUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 80, cacheMissInputTokens: 20),
            previous: previous
        )

        #expect(snapshot.blocks.prefix(3).allSatisfy { $0.stable })
        #expect(record.cacheHitRate == 0.8)
        #expect(record.missReasons.contains(.providerProfileChanged))
        #expect(record.missReasons.contains(.modelChanged))
    }

    @Test func dynamicTaskDoesNotChangePrefixHash() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "# RepoGlass\n")
        let base = ContextBuildRequest(
            systemPrompt: "system",
            toolSchemaText: "tools",
            permissionRules: "permissions",
            projectRules: "rules",
            dependencySummary: "swiftui",
            aiMemory: "memory",
            currentTask: "first task",
            userRequirements: "req"
        )
        let changed = ContextBuildRequest(
            systemPrompt: "system",
            toolSchemaText: "tools",
            permissionRules: "permissions",
            projectRules: "rules",
            dependencySummary: "swiftui",
            aiMemory: "memory",
            currentTask: "second task",
            userRequirements: "different req"
        )

        let engine = ContextEngine()
        let snapshot1 = try engine.buildContext(using: base, workspaceFS: fs)
        let snapshot2 = try engine.buildContext(using: changed, workspaceFS: fs)

        #expect(snapshot1.prefixHash == snapshot2.prefixHash)
    }

    @Test func ignoredPathsDoNotEnterRepoMapAndFileTreeChangesAffectSnapshot() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello\n")
        try fs.writeTextFile(path: ".mobiledevignore", content: "Ignored\n")
        try fs.writeTextFile(path: "Ignored/file.txt", content: "skip\n")
        let request = ContextBuildRequest(
            systemPrompt: "system",
            toolSchemaText: "tools",
            permissionRules: "permissions",
            projectRules: "rules",
            dependencySummary: "swiftui",
            aiMemory: "memory",
            currentTask: "task",
            userRequirements: "req"
        )
        let engine = ContextEngine()
        let snapshot1 = try engine.buildContext(using: request, workspaceFS: fs)
        try fs.writeTextFile(path: "Sources/App.swift", content: "struct App {}\n")
        let snapshot2 = try engine.buildContext(using: request, workspaceFS: fs)

        #expect(snapshot1.includedFiles.contains("Ignored/file.txt") == false)
        #expect(snapshot1.ignoredFiles.contains("Ignored/file.txt"))
        #expect(snapshot1.repoSnapshotHash != snapshot2.repoSnapshotHash)
    }
}

struct AgentLoopTests {
    @Test func stubAIClientStreamsToolCalls() async throws {
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [ToolCall(name: "read_file", arguments: ["path": .string("README.md")])])
        ])
        let request = AIRequest(messages: [AIMessage(role: "user", content: "read")], model: "deepseek-v4-pro", stream: true)

        var toolCallEvents: [(index: Int, id: String?, name: String?, arguments: String)] = []
        for try await event in client.streamComplete(profile: makeProviderProfile(), apiKey: "secret", request: request) {
            if case let .toolCallDelta(index, id, name, arguments) = event {
                toolCallEvents.append((index: index, id: id, name: name, arguments: arguments))
            }
        }

        #expect(toolCallEvents.count == 1)
        #expect(toolCallEvents.first?.index == 0)
        #expect(toolCallEvents.first?.name == "read_file")
        #expect(toolCallEvents.first?.arguments == #"{"path":"README.md"}"#)
    }

    @Test func readFileToolExecutesAutomatically() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello\n")
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [ToolCall(name: "read_file", arguments: ["path": .string("README.md")])]),
            AIResponse(text: "done")
        ])
        let loop = AgentLoop(
            client: client,
            patchStore: patchStore,
            runStore: runStore,
            toolExecutor: toolExecutor,
            permissionManager: PermissionManager(globalMode: .auto)
        )

        let run = try await loop.start(
            workspaceID: UUID(),
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "read"
        )

        #expect(run.status == .completed)
        #expect(run.toolResults.first?.name == "read_file")
    }

    @Test func askQuestionBlocksUntilResume() async throws {
        let fs = try makeWorkspaceFS()
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [
                ToolCall(name: "ask_question", arguments: [
                    "question": .string("Which file?"),
                    "reason": .string("Need scope."),
                    "blocking": .bool(true)
                ])
            ]),
            AIResponse(text: "updated")
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let waiting = try await loop.start(
            workspaceID: UUID(),
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "fix login"
        )
        #expect(waiting.status == .waitingForUser)

        let resumed = try await loop.resume(runID: waiting.id, answer: "README.md", profile: makeProviderProfile(), apiKey: "secret")
        #expect(resumed.status == .completed)
        #expect(resumed.finalAnswer == "updated")
    }

    @Test func proposePatchPersistsReviewQueue() async throws {
        let fs = try makeWorkspaceFS()
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [
                ToolCall(name: "propose_patch", arguments: [
                    "title": .string("Edit README"),
                    "reason": .string("Need docs."),
                    "changes": .array([
                        .object([
                            "path": .string("README.md"),
                            "operation": .string("create"),
                            "newContent": .string("hello\n")
                        ])
                    ])
                ])
            ])
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let run = try await loop.start(
            workspaceID: UUID(),
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "edit docs"
        )

        #expect(run.status == .waitingForPatchReview)
        #expect(try patchStore.list(workspaceID: nil).count == 1)
    }

    @Test func maxRoundsStopsLoop() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello\n")
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: Array(repeating: AIResponse(toolCalls: [ToolCall(name: "read_file", arguments: ["path": .string("README.md")])]), count: 3))
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions, maxRounds: 2)

        await #expect(throws: AgentLoopError.self) {
            _ = try await loop.start(
                workspaceID: UUID(),
                profile: makeProviderProfile(),
                apiKey: "secret",
                modelID: "deepseek-v4-pro",
                systemPrompt: "system",
                userTask: "loop"
            )
        }
    }

    @Test func deniedPermissionReturnsToolResultToModel() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello\n")
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(
            globalMode: .auto,
            toolPolicies: ["read_file": ToolPolicy(toolName: "read_file", permission: .deny)]
        )
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [ToolCall(name: "read_file", arguments: ["path": .string("README.md")])]),
            AIResponse(text: "asked denied")
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let run = try await loop.start(
            workspaceID: UUID(),
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "read secret"
        )

        #expect(run.status == .completed)
        #expect(run.permissionDecisions.first?.permission == .deny)
        #expect(run.toolResults.first?.payload == .object(["denied": .bool(true), "reason": .string("Auto mode follows per-tool policy with hard safety overrides.")]))
    }

    @Test func askPermissionDoesNotExecuteToolBeforeResume() async throws {
        let root = makeTemporaryDirectory()
        let workspaceManager = try WorkspaceManager(baseURL: root)
        let workspace = try workspaceManager.createWorkspace(name: "Demo")
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [makeWorkflowPatchCall()]),
            AIResponse(text: "done")
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let run = try await loop.start(
            workspaceID: workspace.id,
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "update workflow"
        )

        #expect(run.status == .waitingForPermission)
        #expect(run.pendingPermissionRequest?.name == "propose_patch")
        #expect(run.pendingPermissionDecision?.permission == .ask)
        #expect(try patchStore.list(workspaceID: workspace.id).isEmpty)
    }

    @Test func approvePermissionExecutesPendingTool() async throws {
        let root = makeTemporaryDirectory()
        let workspaceManager = try WorkspaceManager(baseURL: root)
        let workspace = try workspaceManager.createWorkspace(name: "Demo")
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [makeWorkflowPatchCall()]),
            AIResponse(text: "approved")
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let waiting = try await loop.start(
            workspaceID: workspace.id,
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "update workflow"
        )
        let resumed = try await loop.resumePermission(runID: waiting.id, approved: true, profile: makeProviderProfile(), apiKey: "secret")

        #expect(resumed.status == .completed)
        #expect(resumed.pendingPermissionRequest == nil)
        #expect(resumed.toolResults.first?.name == "propose_patch")
        #expect(try patchStore.list(workspaceID: workspace.id).count == 1)
    }

    @Test func denyPermissionReturnsDeniedResult() async throws {
        let root = makeTemporaryDirectory()
        let workspaceManager = try WorkspaceManager(baseURL: root)
        let workspace = try workspaceManager.createWorkspace(name: "Demo")
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [
            AIResponse(toolCalls: [makeWorkflowPatchCall()]),
            AIResponse(text: "denied")
        ])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let waiting = try await loop.start(
            workspaceID: workspace.id,
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "update workflow"
        )
        let resumed = try await loop.resumePermission(runID: waiting.id, approved: false, profile: makeProviderProfile(), apiKey: "secret")

        #expect(resumed.status == .completed)
        #expect(resumed.toolResults.first?.payload == .object([
            "denied": .bool(true),
            "reason": .string("Protected credentials or signing files require explicit confirmation.")
        ]))
        #expect(try patchStore.list(workspaceID: workspace.id).isEmpty)
    }

    @Test func pendingPermissionRequestPersists() async throws {
        let root = makeTemporaryDirectory()
        let workspaceManager = try WorkspaceManager(baseURL: root)
        let workspace = try workspaceManager.createWorkspace(name: "Demo")
        let fs = try workspaceManager.workspaceFS(for: workspace)
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let permissions = PermissionManager(globalMode: .auto)
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore)
        let client = StubAIClient(responses: [AIResponse(toolCalls: [makeWorkflowPatchCall()])])
        let loop = AgentLoop(client: client, patchStore: patchStore, runStore: runStore, toolExecutor: toolExecutor, permissionManager: permissions)

        let waiting = try await loop.start(
            workspaceID: workspace.id,
            profile: makeProviderProfile(),
            apiKey: "secret",
            modelID: "deepseek-v4-pro",
            systemPrompt: "system",
            userTask: "update workflow"
        )
        let persisted = try #require(try runStore.run(id: waiting.id))

        #expect(persisted.pendingPermissionRequest?.name == "propose_patch")
        #expect(persisted.pendingPermissionDecision?.permission == .ask)
        #expect(persisted.status == .waitingForPermission)
    }
}

struct SecretStoreTests {
    @Test func saveReadDeleteInMemorySecretStore() async throws {
        let store = InMemorySecretStore()

        try store.save(service: "provider", account: "default", value: "secret")
        #expect(try store.exists(service: "provider", account: "default"))
        #expect(try store.read(service: "provider", account: "default") == "secret")

        try store.delete(service: "provider", account: "default")
        #expect((try store.read(service: "provider", account: "default")) == nil)
    }

    @Test func providerProfileExportDoesNotContainPlaintextKey() async throws {
        var profile = makeProviderProfile()
        profile.apiKeyReference = "provider.default"
        let plaintextKey = "super-secret"

        let data = try JSONEncoder().encode(profile)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("provider.default"))
        #expect(json.contains(plaintextKey) == false)
    }
}

struct WorkspaceManagerTests {
    @Test func createWorkspaceUsesFilesRootAndPersistsMetadata() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)

        let workspace = try manager.createWorkspace(name: "Repo")
        let reopened = try manager.openWorkspace(id: workspace.id)
        let fs = try manager.workspaceFS(for: reopened)

        #expect(reopened.rootPath.hasSuffix("/files"))
        #expect(fs.rootURL.path == reopened.rootPath)
        #expect(reopened.lastOpenedAt != nil)
        #expect(FileManager.default.fileExists(atPath: manager.mobiledevURL(for: workspace.id).appendingPathComponent("workspace.json").path))
    }

    @Test func deleteWorkspaceRemovesMetadataAndFiles() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")

        try manager.deleteWorkspace(id: workspace.id)

        #expect(FileManager.default.fileExists(atPath: manager.workspaceURL(for: workspace.id).path) == false)
    }
}

struct PatchReviewServiceTests {
    @Test func applyPatchUpdatesStatus() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let fs = try manager.workspaceFS(for: workspace)
        try fs.writeTextFile(path: "README.md", content: "before\n")
        let base = try fs.readTextFile(path: "README.md")
        let store = InMemoryPatchStore()
        let proposal = PatchProposal(
            workspaceID: workspace.id,
            title: "Update",
            changes: [PatchChange(path: "README.md", operation: .modify, baseHash: base.hash, diff: "@@ -1 +1 @@\n-before\n+after")],
            reason: "docs",
            changedFiles: 1,
            changedLines: 2
        )
        try store.save(proposal)
        let service = PatchReviewService(patchStore: store, workspaceManager: manager, permissionManager: PermissionManager(globalMode: .auto))

        let applied = try service.apply(proposalID: proposal.id, confirmedByUser: true)

        #expect(applied.status == .applied)
        #expect(applied.snapshotID != nil)
    }

    @Test func rejectPatchUpdatesStatus() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let store = InMemoryPatchStore()
        let proposal = PatchProposal(workspaceID: workspace.id, title: "Update", changes: [], reason: "docs")
        try store.save(proposal)
        let service = PatchReviewService(patchStore: store, workspaceManager: manager, permissionManager: PermissionManager(globalMode: .auto))

        let rejected = try service.reject(proposalID: proposal.id)

        #expect(rejected.status == .rejected)
    }

    @Test func applyFailureWritesErrorMessage() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let store = InMemoryPatchStore()
        let proposal = PatchProposal(
            workspaceID: workspace.id,
            title: "Broken",
            changes: [PatchChange(path: "README.md", operation: .modify, baseHash: "missing", diff: "@@ -1 +1 @@\n-a\n+b")],
            reason: "docs",
            changedFiles: 1,
            changedLines: 2
        )
        try store.save(proposal)
        let service = PatchReviewService(patchStore: store, workspaceManager: manager, permissionManager: PermissionManager(globalMode: .auto))

        #expect(throws: Error.self) {
            _ = try service.apply(proposalID: proposal.id, confirmedByUser: true)
        }
        let failed = try #require(try store.proposal(id: proposal.id))
        #expect(failed.status == .failed)
        #expect(failed.errorMessage?.isEmpty == false)
    }

    @Test func protectedPatchRequiresConfirmation() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let fs = try manager.workspaceFS(for: workspace)
        try fs.writeTextFile(path: ".mobiledev/cache/state.json", content: "{}", allowProtectedPaths: true)
        let baseHash = try fs.hashForFile(at: ".mobiledev/cache/state.json", allowProtectedPaths: true)
        let store = InMemoryPatchStore()
        let proposal = PatchProposal(
            workspaceID: workspace.id,
            title: "Protected",
            changes: [PatchChange(path: ".mobiledev/cache/state.json", operation: .modify, baseHash: baseHash, diff: "@@ -1 +1 @@\n-{}\n+{\"ok\":true}")],
            reason: "cache",
            changedFiles: 1,
            changedLines: 2
        )
        try store.save(proposal)
        let service = PatchReviewService(patchStore: store, workspaceManager: manager, permissionManager: PermissionManager(globalMode: .auto))

        #expect(throws: Error.self) {
            _ = try service.apply(proposalID: proposal.id, confirmedByUser: false)
        }
    }
}

struct WorkspaceImportServiceTests {
    @Test func singleFileImportCopiesIntoWorkspaceFiles() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let source = root.appendingPathComponent("Input.txt")
        try "hello".data(using: .utf8)?.write(to: source)

        let result = try WorkspaceImportService(workspaceManager: manager).importSingleFile(sourceURL: source, workspaceID: workspace.id, destinationPath: "Docs")
        let imported = try manager.workspaceFS(for: workspace).readTextFile(path: "Docs/Input.txt")

        #expect(imported.content == "hello")
        #expect(result.importedCount == 1)
    }

    @Test func zipSlipIsRejected() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let zipURL = root.appendingPathComponent("danger.zip")
        try makeZip(at: zipURL, entries: ["../escape.txt": "bad"])

        #expect(throws: WorkspaceImportError.self) {
            _ = try WorkspaceImportService(workspaceManager: manager).importZip(sourceURL: zipURL, workspaceID: workspace.id)
        }
    }

    @Test func zipImportIgnoresMacOSMetadata() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let zipURL = root.appendingPathComponent("project.zip")
        try makeZip(at: zipURL, entries: [
            "__MACOSX/._a.txt": "ignore",
            ".DS_Store": "ignore",
            "Sources/App.swift": "struct App {}"
        ])

        _ = try WorkspaceImportService(workspaceManager: manager).importZip(sourceURL: zipURL, workspaceID: workspace.id)
        let files = try manager.workspaceFS(for: workspace).listFiles().map(\.path)

        #expect(files.contains("Sources/App.swift"))
        #expect(files.contains(where: { $0.contains("__MACOSX") }) == false)
        #expect(files.contains(".DS_Store") == false)
    }
}

struct GitHubSyncServiceTests {
    @Test func remoteConfigDoesNotPersistToken() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let secrets = InMemorySecretStore()
        let client = StubGitHubAPIClient()
        let service = GitHubSyncService(workspaceManager: manager, secretStore: secrets, client: client)

        _ = try await service.linkRepository(workspaceID: workspace.id, owner: "testorg", repo: "sample-repo", branch: "main", token: "ghs_secret")
        let remoteData = try Data(contentsOf: manager.mobiledevURL(for: workspace.id).appendingPathComponent("github/remote.json"))
        let remoteJSON = String(decoding: remoteData, as: UTF8.self)

        #expect(remoteJSON.contains("ghs_secret") == false)
        #expect(try secrets.read(service: GitHubSyncService.secretService, account: "github.default") == "ghs_secret")
    }

    @Test func commitTreeSkipsMobiledevAndBinaryFiles() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let fs = try manager.workspaceFS(for: workspace)
        try fs.writeTextFile(path: "README.md", content: "hello")
        try fs.writeTextFile(path: ".mobiledev/builds.json", content: "{}")
        try Data([0, 1, 2, 3]).write(to: try fs.safeURL(for: "blob.bin"))

        let secrets = InMemorySecretStore()
        try secrets.save(service: GitHubSyncService.secretService, account: "github.default", value: "token")
        let client = StubGitHubAPIClient()
        let service = GitHubSyncService(workspaceManager: manager, secretStore: secrets, client: client)
        let remote = GitHubRemoteConfig(owner: "testorg", repo: "sample-repo", branch: "feature", remoteURL: "https://github.com/testorg/sample-repo", tokenReference: "github.default")
        try JSONEncoder.pretty.encode(remote).write(to: manager.mobiledevURL(for: workspace.id).appendingPathComponent("github/remote.json"))

        let summary = try await service.commitWorkspaceChanges(workspaceID: workspace.id, message: "sync")

        #expect(summary.changedFiles.map(\.path) == ["README.md"])
        #expect(summary.skippedFiles.contains(where: { $0.path == "blob.bin" }))
        let createdPaths = await client.createdTreeEntries
        #expect(createdPaths == ["README.md"])
    }

    @Test func protectedBranchPushRequiresSecondConfirmation() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let secrets = InMemorySecretStore()
        try secrets.save(service: GitHubSyncService.secretService, account: "github.default", value: "token")
        let service = GitHubSyncService(workspaceManager: manager, secretStore: secrets, client: StubGitHubAPIClient())
        let remote = GitHubRemoteConfig(owner: "testorg", repo: "sample-repo", branch: "main", remoteURL: "https://github.com/testorg/sample-repo", tokenReference: "github.default")
        try JSONEncoder.pretty.encode(remote).write(to: manager.mobiledevURL(for: workspace.id).appendingPathComponent("github/remote.json"))

        await #expect(throws: GitHubSyncError.self) {
            _ = try await service.pushWorkspaceToBranch(workspaceID: workspace.id, message: "push", confirmed: true, secondProtectedBranchConfirmation: false)
        }
    }
}

struct BuildConfigLoaderTests {
    @Test func buildsJsonParsingHonorsPriority() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let high = manager.filesURL(for: workspace.id).appendingPathComponent(".mobiledev/builds.json")
        try FileManager.default.createDirectory(at: high.deletingLastPathComponent(), withIntermediateDirectories: true)
        let low = manager.filesURL(for: workspace.id).appendingPathComponent("mobiledev-builds.json")
        try Data("{\"name\":\"Low\",\"builds\":[]}".utf8).write(to: low)
        try Data("{\"name\":\"High\",\"builds\":[{\"name\":\"iOS\",\"workflow\":\"build-ios.yml\",\"ref\":\"main\",\"artifact\":\"*.ipa\",\"inputs\":{\"configuration\":\"release\"}}]}".utf8).write(to: high)

        let config = try BuildConfigLoader(workspaceManager: manager).load(workspaceID: workspace.id)

        #expect(config?.name == "High")
        #expect(config?.builds.first?.workflow == "build-ios.yml")
    }
}

struct PromptBuilderTests {
    @Test func staticPrefixComesBeforeDynamicAndOmitsSecrets() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello")
        let request = ContextBuildRequest(systemPrompt: "system", toolSchemaText: "tools", permissionRules: "rules", projectRules: "project", dependencySummary: "deps", aiMemory: "memory", currentTask: "task", userRequirements: "req")
        let snapshot = try ContextEngine().buildContext(using: request, workspaceFS: fs)
        var workspace = Workspace(name: "Repo", rootPath: fs.rootURL.path, mode: .localOnly, status: WorkspaceStatus(contextReady: true, cachePrefixStable: true))
        workspace.currentBranch = "feature"
        let provider = makeProviderProfile()
        let prompt = PromptBuilder().build(snapshot: snapshot, userTask: "fix", toolSchemas: SupportedTools.schemas, permissionRules: "git_push: ask", activeProvider: provider, activeModel: provider.modelProfiles[0], workspace: workspace, additionalUserRequirements: "do not leak api key")

        #expect(prompt.contextMessage.contains("[STATIC PREFIX START]"))
        #expect(prompt.contextMessage.contains("[DYNAMIC TASK START]"))
        #expect(prompt.contextMessage.range(of: "[STATIC PREFIX START]")!.lowerBound < prompt.contextMessage.range(of: "[DYNAMIC TASK START]")!.lowerBound)
        #expect(prompt.contextMessage.contains("list_files"))
        #expect(prompt.contextMessage.contains("repo map"))
        #expect(prompt.contextMessage.contains("super-secret") == false)
    }
}

struct ProviderProfileImportTests {
    @Test func importClearsApiKeyReference() async throws {
        var profile = makeProviderProfile()
        profile.apiKeyReference = "provider.saved"

        let imported = try ProviderProfile.imported(from: profile.exportedData())

        #expect(imported.apiKeyReference == nil)
    }
}

struct SnapshotRestoreTests {
    @Test func restoreSnapshotRestoresOriginalFile() async throws {
        let root = makeTemporaryDirectory()
        let manager = try WorkspaceManager(baseURL: root)
        let workspace = try manager.createWorkspace(name: "Repo")
        let fs = try manager.workspaceFS(for: workspace)
        try fs.writeTextFile(path: "README.md", content: "before\n")
        let base = try fs.readTextFile(path: "README.md")
        let proposal = PatchProposal(workspaceID: workspace.id, title: "Update", changes: [PatchChange(path: "README.md", operation: .modify, baseHash: base.hash, diff: "@@ -1 +1 @@\n-before\n+after")], reason: "docs")
        let patchStore = InMemoryPatchStore()
        try patchStore.save(proposal)
        let snapshotStore = FileSnapshotStore(storageURL: manager.mobiledevURL(for: workspace.id).appendingPathComponent("snapshots.json"))
        let service = PatchReviewService(patchStore: patchStore, workspaceManager: manager, permissionManager: PermissionManager(globalMode: .auto), snapshotStore: snapshotStore)

        let applied = try service.apply(proposalID: proposal.id, confirmedByUser: true)
        try service.restoreSnapshot(snapshotID: try #require(applied.snapshotID), workspaceID: workspace.id, confirmedByUser: true)

        #expect(try fs.readTextFile(path: "README.md").content == "before\n")
    }
}

private func makeWorkspaceFS() throws -> WorkspaceFS {
    try WorkspaceFS(rootURL: makeTemporaryDirectory())
}

private func makeTemporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeProviderProfile() -> ProviderProfile {
    ProviderProfile(
        id: "custom-openai",
        name: "Custom OpenAI-Compatible",
        apiStyle: .openAICompatible,
        baseURL: "https://api.example.com/v1",
        endpoint: "/chat/completions",
        auth: AuthConfiguration(type: .bearer),
        supportsStreaming: true,
        supportsToolCalling: true,
        supportsJSONMode: true,
        supportsVision: false,
        supportsReasoning: true,
        supportsPromptCache: true,
        supportsExplicitCacheControl: false,
        supportsWebSearch: true,
        requestFieldMapping: ["webSearch": "web_search"],
        extraBodyParameters: ["metadata.env": .string("test")],
        modelProfiles: [
            ModelProfile(
                id: "deepseek-v4-pro",
                displayName: "DeepSeek V4 Pro",
                supportsReasoning: true,
                reasoningMapping: ReasoningMapping(
                    enabledField: "enable_thinking",
                    depthField: "thinking_level",
                    levels: [
                        ReasoningLevel(label: "High", value: "high")
                    ]
                ),
                supportsCache: true,
                cacheStrategy: .automaticPrefix,
                supportsTools: true,
                supportsStreaming: true,
                maxContextTokens: 128_000,
                maxOutputTokens: 8_000
            )
        ]
    )
}

private func makeWorkflowPatchCall() -> ToolCall {
    ToolCall(name: "propose_patch", arguments: [
        "title": .string("Update workflow"),
        "reason": .string("Needs confirmation."),
        "changes": .array([
            .object([
                "path": .string(".github/workflows/build-ios.yml"),
                "operation": .string("create"),
                "newContent": .string("name: build\n")
            ])
        ])
    ])
}

private final class StubAIClient: AIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [AIResponse]

    init(responses: [AIResponse]) {
        self.responses = responses
    }

    private func nextResponse() -> AIResponse {
        lock.lock()
        defer { lock.unlock() }
        return responses.isEmpty ? AIResponse(text: "done") : responses.removeFirst()
    }

    func complete(profile: ProviderProfile, apiKey: String?, request: AIRequest) async throws -> AIResponse {
        nextResponse()
    }

    func streamComplete(profile: ProviderProfile, apiKey: String?, request: AIRequest) -> AsyncThrowingStream<AIClientStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let response = self.nextResponse()
            if let rc = response.reasoningContent, !rc.isEmpty {
                continuation.yield(.reasoningDelta(rc))
            }
            if let text = response.text, !text.isEmpty {
                continuation.yield(.textDelta(text))
            }
            for (index, call) in response.toolCalls.enumerated() {
                let encoder = JSONEncoder()
                let arguments = (try? encoder.encode(call.arguments))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                continuation.yield(.toolCallDelta(index: index, id: call.externalID, name: call.name, arguments: arguments))
            }
            continuation.yield(.done(text: response.text ?? "", reasoning: response.reasoningContent ?? "", usage: response.usage))
            continuation.finish()
        }
    }
}

private actor StubGitHubAPIClient: GitHubAPIClient {
    var createdTreeEntries: [String] = []

    func getRepository(owner: String, repo: String, token: String) async throws -> GitHubRepository {
        GitHubRepository(id: 1, fullName: "\(owner)/\(repo)", private: false, defaultBranch: "main", htmlURL: "https://github.com/\(owner)/\(repo)")
    }

    func getBranchRef(owner: String, repo: String, branch: String, token: String) async throws -> GitHubBranchRef {
        GitHubBranchRef(ref: "refs/heads/\(branch)", sha: "head-sha")
    }

    func getLatestCommit(owner: String, repo: String, branchOrSHA: String, token: String) async throws -> GitHubCommit {
        GitHubCommit(sha: "head-sha", url: nil, message: "latest")
    }

    func getGitCommitTreeSHA(owner: String, repo: String, commitSHA: String, token: String) async throws -> String {
        "base-tree"
    }

    func createBlob(owner: String, repo: String, content: Data, isBinary: Bool, token: String) async throws -> String {
        StableHasher.fnv1a64(data: content)
    }

    func createTree(owner: String, repo: String, baseTree: String?, entries: [GitTreeEntry], token: String) async throws -> String {
        createdTreeEntries = entries.map(\.path)
        return "tree-sha"
    }

    func createCommit(owner: String, repo: String, message: String, treeSHA: String, parents: [String], token: String) async throws -> GitHubCommit {
        GitHubCommit(sha: "commit-sha", url: nil, message: message)
    }

    func updateRef(owner: String, repo: String, branch: String, sha: String, force: Bool, token: String) async throws {}

    func createPullRequest(owner: String, repo: String, title: String, body: String, head: String, base: String, token: String) async throws -> String {
        "https://github.com/\(owner)/\(repo)/pull/1"
    }

    func listWorkflows(owner: String, repo: String, token: String) async throws -> [GitHubWorkflow] { [] }
    func dispatchWorkflow(owner: String, repo: String, workflowIDOrFileName: String, ref: String, inputs: [String : String], token: String) async throws {}
    func listWorkflowRuns(owner: String, repo: String, branch: String?, token: String) async throws -> [GitHubWorkflowRun] { [] }
    func getWorkflowRun(owner: String, repo: String, runID: Int, token: String) async throws -> GitHubWorkflowRun { GitHubWorkflowRun(id: runID) }
    func listJobsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubWorkflowJob] { [] }
    func listArtifactsForRun(owner: String, repo: String, runID: Int, token: String) async throws -> [GitHubArtifact] { [] }
    func downloadArtifactArchive(owner: String, repo: String, artifactID: Int, token: String) async throws -> Data { Data() }
}

private func makeZip(at url: URL, entries: [String: String]) throws {
    let temp = makeTemporaryDirectory()
    for (path, content) in entries {
        let fileURL = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL, options: .atomic)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = temp
    process.arguments = ["-q", "-r", url.path] + entries.keys.sorted()
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "zip", code: Int(process.terminationStatus))
    }
}
