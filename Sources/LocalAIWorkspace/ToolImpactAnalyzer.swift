import Foundation

public struct ToolImpact: Hashable, Sendable {
    public var changedFiles: Int
    public var changedLines: Int
    public var touchedPaths: [String]
    public var touchesProtectedPath: Bool
    public var isDestructive: Bool

    public init(
        changedFiles: Int = 0,
        changedLines: Int = 0,
        touchedPaths: [String] = [],
        touchesProtectedPath: Bool = false,
        isDestructive: Bool = false
    ) {
        self.changedFiles = changedFiles
        self.changedLines = changedLines
        self.touchedPaths = touchedPaths
        self.touchesProtectedPath = touchesProtectedPath
        self.isDestructive = isDestructive
    }
}

public enum ToolImpactAnalyzer {
    private static let protectedPathPrefixes = [
        ".mobiledev",
        ".github/workflows",
        "Secrets",
        "DerivedData",
        "signing"
    ]

    public static func estimate(_ call: ToolCall) -> ToolImpact {
        switch call.name {
        case "propose_patch":
            let changes = decodePatchChanges(from: call.arguments["changes"])
            let touchedPaths = changes.flatMap { [Optional($0.path), $0.newPath].compactMap { $0 } }
            return ToolImpact(
                changedFiles: max(changes.count, touchedPaths.count),
                changedLines: estimateChangedLines(in: changes),
                touchedPaths: touchedPaths,
                touchesProtectedPath: touchesProtectedPath(in: touchedPaths),
                isDestructive: changes.contains { change in
                    change.operation == .delete || change.operation == .rename
                }
            )

        case "propose_delete_file", "delete_workspace":
            let paths = allPaths(from: call.arguments)
            return ToolImpact(
                changedFiles: max(1, paths.count),
                changedLines: 1,
                touchedPaths: paths,
                touchesProtectedPath: touchesProtectedPath(in: paths),
                isDestructive: true
            )

        case "propose_rename_file", "git_push", "trigger_github_action":
            let paths = allPaths(from: call.arguments)
            return ToolImpact(
                changedFiles: max(paths.count, 1),
                changedLines: 1,
                touchedPaths: paths,
                touchesProtectedPath: touchesProtectedPath(in: paths),
                isDestructive: false
            )

        default:
            let paths = allPaths(from: call.arguments)
            return ToolImpact(
                touchedPaths: paths,
                touchesProtectedPath: touchesProtectedPath(in: paths)
            )
        }
    }

    private static func decodePatchChanges(from value: JSONValue?) -> [PatchChange] {
        guard case let .array(items)? = value else { return [] }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return items.compactMap { item in
            guard let data = try? encoder.encode(item) else { return nil }
            return try? decoder.decode(PatchChange.self, from: data)
        }
    }

    private static func estimateChangedLines(in changes: [PatchChange]) -> Int {
        changes.reduce(into: 0) { total, change in
            switch change.operation {
            case .modify:
                total += change.diff?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { line in
                        guard let prefix = line.first else { return false }
                        return prefix == "+" || prefix == "-"
                    }
                    .count ?? 0
            case .create:
                total += change.newContent?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
            case .delete, .rename:
                total += 1
            }
        }
    }

    private static func touchesProtectedPath(in paths: [String]) -> Bool {
        paths.contains { path in
            protectedPathPrefixes.contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/") || path.localizedCaseInsensitiveContains(prefix)
            }
        }
    }

    private static func allPaths(from arguments: [String: JSONValue]) -> [String] {
        var paths: [String] = []
        for (key, value) in arguments where key.localizedCaseInsensitiveContains("path") || key == "paths" {
            switch value {
            case let .string(path):
                paths.append(path)
            case let .array(items):
                for item in items {
                    if case let .string(path) = item {
                        paths.append(path)
                    }
                }
            default:
                break
            }
        }
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }
}
