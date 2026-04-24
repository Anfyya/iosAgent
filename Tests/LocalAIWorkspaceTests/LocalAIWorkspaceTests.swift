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
}

struct PermissionManagerTests {
    @Test func workflowChangesAlwaysAsk() async throws {
        let manager = PermissionManager(globalMode: .auto)
        let call = ToolCall(name: "propose_patch", arguments: ["path": .string(".github/workflows/build-ios.yml")])

        let decision = manager.decide(for: call)
        #expect(decision.permission == .ask)
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
}

struct AgentLoopTests {
    @Test func readFileToolExecutesAutomatically() async throws {
        let fs = try makeWorkspaceFS()
        try fs.writeTextFile(path: "README.md", content: "hello\n")
        let patchStore = InMemoryPatchStore()
        let runStore = InMemoryAgentRunStore()
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore, permissionManager: PermissionManager(globalMode: .auto))
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
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore, permissionManager: permissions)
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
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore, permissionManager: permissions)
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
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore, permissionManager: permissions)
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
        let toolExecutor = ToolExecutor(workspaceFS: fs, contextEngine: ContextEngine(), patchStore: patchStore, permissionManager: permissions)
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

private actor StubAIClient: AIClient {
    private var responses: [AIResponse]

    init(responses: [AIResponse]) {
        self.responses = responses
    }

    func complete(profile: ProviderProfile, apiKey: String?, request: AIRequest) async throws -> AIResponse {
        return responses.isEmpty ? AIResponse(text: "done") : responses.removeFirst()
    }
}
