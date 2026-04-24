import LocalAIWorkspace
import SwiftUI

final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = [MVPSampleData.defaultWorkspace]
    @Published var providerProfiles: [ProviderProfile] = [MVPSampleData.defaultProvider]
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var patchQueue: [PatchProposal] = [MVPSampleData.samplePatch]
    @Published var selectedTab: AppTab = .projects
    @Published var cacheRecord: CacheRecord = CacheRecord(
        provider: MVPSampleData.defaultProvider.name,
        model: MVPSampleData.defaultProvider.modelProfiles[0].id,
        apiStyle: MVPSampleData.defaultProvider.apiStyle,
        promptTokens: 82_000,
        completionTokens: 2_100,
        cachedTokens: 71_000,
        cacheMissTokens: 11_000,
        cacheHitRate: 0.865,
        prefixHash: "a8f3-demo-prefix",
        repoSnapshotHash: "stable-repo-snapshot",
        toolSchemaHash: "tool-schema-hash",
        projectRulesHash: "project-rules-hash",
        fileTreeHash: "file-tree-hash",
        symbolIndexHash: "symbol-index-hash",
        staticPrefixTokenCount: 72_000,
        dynamicTokenCount: 10_000,
        estimatedCost: 1.28,
        estimatedSavedCost: 0.42,
        latencyMs: 9_200,
        timeToFirstTokenMs: 1_200,
        cacheStrategy: .automaticPrefix,
        missReasons: [.prefixHashChanged]
    )

    @Published var recentToolCalls: [ToolCall] = [
        ToolCall(name: "list_files", arguments: [:]),
        ToolCall(name: "read_file", arguments: ["path": .string("Sources/App/LoginView.swift")]),
        ToolCall(name: "propose_patch", arguments: ["title": .string("Guard repeated login tap")])
    ]

    @Published var currentQuestion = ToolCall(
        name: "ask_question",
        arguments: [
            "question": .string("Do you want the patch applied locally only, or also prepared for GitHub sync?"),
            "reason": .string("GitHub sync is optional and should not be assumed."),
            "blocking": .bool(true)
        ]
    )

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == (selectedWorkspaceID ?? workspaces.first?.id) }
    }

    init() {
        selectedWorkspaceID = workspaces.first?.id
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case projects
    case workspace
    case chat
    case patches
    case context
    case cache
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .workspace: "Workspace"
        case .chat: "Chat"
        case .patches: "Patch Review"
        case .context: "Context"
        case .cache: "Cache"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .projects: "folder"
        case .workspace: "square.grid.2x2"
        case .chat: "bubble.left.and.bubble.right"
        case .patches: "square.and.pencil"
        case .context: "text.redaction"
        case .cache: "speedometer"
        case .settings: "gearshape"
        }
    }
}
