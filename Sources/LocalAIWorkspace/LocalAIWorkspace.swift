import Foundation

public enum MVPSampleData {
    public static let defaultWorkspace = Workspace(
        name: "RepoGlass Demo",
        rootPath: "/Workspaces/RepoGlass/files",
        mode: .localOnly,
        currentBranch: "feature/mvp",
        status: WorkspaceStatus(
            contextReady: true,
            cachePrefixStable: true,
            lastAIRunAt: .now,
            lastSnapshotAt: .now
        )
    )

    public static let defaultProvider = ProviderProfile(
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
        supportsWebSearch: false,
        modelProfiles: [
            ModelProfile(
                id: "deepseek-v4-pro",
                displayName: "DeepSeek V4 Pro",
                supportsReasoning: true,
                reasoningMapping: ReasoningMapping(
                    enabledField: "enable_thinking",
                    depthField: "thinking_level",
                    levels: [
                        ReasoningLevel(label: "低", value: "low"),
                        ReasoningLevel(label: "高", value: "high"),
                        ReasoningLevel(label: "最大", value: "max")
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

    public static let samplePatch = PatchProposal(
        title: "Guard repeated login tap",
        changes: [
            PatchChange(
                path: "Sources/App/LoginView.swift",
                operation: .modify,
                baseHash: "abc123",
                diff: "@@ -1,3 +1,5 @@\n Button(\"Login\") {\n+    guard !isLoading else { return }\n+    isLoading = true\n     login()\n }"
            )
        ],
        reason: "Prevent duplicate login requests while a request is already running."
    )
}
