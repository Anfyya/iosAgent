import Foundation
import LocalAIWorkspace

enum ModelPermissionMode: String, Codable, CaseIterable, Identifiable {
    case fullAccess
    case readOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullAccess:
            return "全权限"
        case .readOnly:
            return "确认模式"
        }
    }

    var summary: String {
        switch self {
        case .fullAccess:
            return "模型提出的文件补丁会自动应用到当前项目。"
        case .readOnly:
            return "写入、删除和重命名需要先确认。"
        }
    }

    var globalPermissionMode: GlobalPermissionMode {
        switch self {
        case .fullAccess:
            return .auto
        case .readOnly:
            return .manual
        }
    }

    var toolPolicies: [String: ToolPolicy] {
        var policies = PermissionManager.defaultPolicies
        switch self {
        case .fullAccess:
            policies["propose_patch"] = ToolPolicy(
                toolName: "propose_patch",
                permission: .automatic,
                maxFilesWithoutConfirmation: 100,
                maxChangedLinesWithoutConfirmation: 20_000,
                requireConfirmationOnMainBranch: false
            )
        case .readOnly:
            policies["propose_patch"] = ToolPolicy(
                toolName: "propose_patch",
                permission: .ask,
                maxFilesWithoutConfirmation: 0,
                maxChangedLinesWithoutConfirmation: 0,
                requireConfirmationOnMainBranch: true
            )
        }
        return policies
    }
}

enum ReasoningEffortPreset: String, Codable, CaseIterable, Identifiable {
    case high
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:
            return "高"
        case .max:
            return "极限"
        }
    }
}

struct AppPreferences: Codable, Hashable {
    var selectedProviderID: String?
    var permissionMode: ModelPermissionMode
    var defaultReasoningEffort: ReasoningEffortPreset

    init(
        selectedProviderID: String? = nil,
        permissionMode: ModelPermissionMode = .fullAccess,
        defaultReasoningEffort: ReasoningEffortPreset = .high
    ) {
        self.selectedProviderID = selectedProviderID
        self.permissionMode = permissionMode
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

enum BuiltInModelProfiles {
    static func deepSeekDefaults() -> [ProviderProfile] {
        [
            deepSeekProfile(
                id: "deepseek-v4-pro",
                name: "DeepSeek V4 Pro",
                modelID: "deepseek-v4-pro"
            ),
            deepSeekProfile(
                id: "deepseek-v4-flash",
                name: "DeepSeek V4 Flash",
                modelID: "deepseek-v4-flash"
            )
        ]
    }

    private static func deepSeekProfile(id: String, name: String, modelID: String) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            apiStyle: .openAICompatible,
            baseURL: "https://api.deepseek.com",
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
                    id: modelID,
                    displayName: name,
                    supportsReasoning: true,
                    reasoningMapping: ReasoningMapping(
                        enabledField: "thinking.type",
                        depthField: "reasoning_effort",
                        levels: [
                            ReasoningLevel(label: "高", value: "high"),
                            ReasoningLevel(label: "极限", value: "max")
                        ]
                    ),
                    supportsCache: true,
                    cacheStrategy: .automaticPrefix,
                    supportsTools: true,
                    supportsStreaming: true,
                    maxContextTokens: 1_000_000,
                    maxOutputTokens: 384_000
                )
            ]
        )
    }
}
