import Foundation

public struct PermissionManager: Sendable {
    public var globalMode: GlobalPermissionMode
    public var toolPolicies: [String: ToolPolicy]

    public init(globalMode: GlobalPermissionMode, toolPolicies: [String: ToolPolicy] = PermissionManager.defaultPolicies) {
        self.globalMode = globalMode
        self.toolPolicies = toolPolicies
    }

    public static let defaultPolicies: [String: ToolPolicy] = {
        let policies: [ToolPolicy] = [
            .init(toolName: "list_files", permission: .automatic),
            .init(toolName: "read_file", permission: .automatic),
            .init(toolName: "search_in_files", permission: .automatic),
            .init(toolName: "get_file_hash", permission: .automatic),
            .init(toolName: "get_context_status", permission: .automatic),
            .init(toolName: "ask_question", permission: .automatic),
            .init(toolName: "propose_patch", permission: .automatic, maxFilesWithoutConfirmation: 3, maxChangedLinesWithoutConfirmation: 120),
            .init(toolName: "propose_create_file", permission: .review),
            .init(toolName: "propose_delete_file", permission: .ask),
            .init(toolName: "propose_rename_file", permission: .ask),
            .init(toolName: "apply_patch", permission: .review),
            .init(toolName: "git_commit", permission: .ask),
            .init(toolName: "git_push", permission: .ask),
            .init(toolName: "create_pull_request", permission: .ask),
            .init(toolName: "trigger_github_action", permission: .ask),
            .init(toolName: "download_artifact", permission: .automatic),
            .init(toolName: "modify_provider_profile", permission: .ask)
        ]

        return Dictionary(uniqueKeysWithValues: policies.map { ($0.toolName, $0) })
    }()

    public func decide(for call: ToolCall, changedFiles: Int = 0, changedLines: Int = 0, currentBranch: String? = nil) -> PermissionDecision {
        if matchesSecretOrCredentialPath(arguments: call.arguments) {
            return PermissionDecision(permission: .ask, reason: "Protected credentials or signing files require explicit confirmation.")
        }

        if touchesWorkflow(arguments: call.arguments) {
            return PermissionDecision(permission: .ask, reason: "Workflow changes always require confirmation.")
        }

        if call.name == "git_push", ["main", "master"].contains(currentBranch ?? "") {
            return PermissionDecision(permission: .ask, reason: "Pushing to a protected branch requires confirmation.")
        }

        if call.name == "propose_delete_file" || call.name == "delete_workspace" {
            return PermissionDecision(permission: .ask, reason: "Destructive operations require confirmation.")
        }

        if changedFiles > 5 || changedLines > 400 {
            return PermissionDecision(permission: .ask, reason: "Large changes require confirmation.")
        }

        guard let policy = toolPolicies[call.name] else {
            return PermissionDecision(permission: .ask, reason: "Unknown tool falls back to ask.")
        }

        switch globalMode {
        case .manual:
            if policy.permission == .automatic {
                return PermissionDecision(permission: .automatic, reason: "Read-only tools stay automatic in Manual mode.")
            }
            return PermissionDecision(permission: minPermission(policy.permission, .review), reason: "Manual mode routes mutating tools through review.")
        case .semiAuto:
            if policy.permission == .automatic || policy.permission == .review {
                return PermissionDecision(permission: policy.permission, reason: "Semi-Auto keeps read/proposal tools automatic or review-based.")
            }
            return PermissionDecision(permission: .ask, reason: "Semi-Auto asks before risky actions.")
        case .auto:
            return PermissionDecision(permission: policy.permission, reason: "Auto mode follows per-tool policy with hard safety overrides.")
        }
    }

    private func minPermission(_ lhs: ToolPermission, _ rhs: ToolPermission) -> ToolPermission {
        let order: [ToolPermission] = [.deny, .manualOnly, .ask, .review, .automatic]
        guard let lhsIndex = order.firstIndex(of: lhs), let rhsIndex = order.firstIndex(of: rhs) else {
            return .ask
        }
        return order[min(lhsIndex, rhsIndex)]
    }

    private func touchesWorkflow(arguments: [String: JSONValue]) -> Bool {
        allPaths(from: arguments).contains { $0.hasPrefix(".github/workflows") }
    }

    private func matchesSecretOrCredentialPath(arguments: [String: JSONValue]) -> Bool {
        let sensitiveSuffixes = [".env", ".key", ".pem", ".p12", ".mobileprovision"]
        let sensitiveSegments = ["Secrets", "secret", "signing", "provider_profiles"]
        return allPaths(from: arguments).contains { path in
            sensitiveSuffixes.contains(where: { path.hasSuffix($0) }) || sensitiveSegments.contains(where: { path.localizedCaseInsensitiveContains($0) })
        }
    }

    private func allPaths(from arguments: [String: JSONValue]) -> [String] {
        var paths: [String] = []

        for (key, value) in arguments where key.localizedCaseInsensitiveContains("path") || key == "paths" {
            switch value {
            case let .string(path):
                paths.append(path)
            case let .array(values):
                for item in values {
                    if case let .string(path) = item {
                        paths.append(path)
                    }
                }
            default:
                break
            }
        }

        return paths
    }
}
