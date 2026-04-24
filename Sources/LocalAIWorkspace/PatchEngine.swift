import Foundation

public enum PatchEngineError: Error, LocalizedError {
    case missingBaseHash(String)
    case baseHashMismatch(path: String, expected: String, actual: String)
    case missingDiff(String)
    case invalidDiff(String)
    case missingNewContent(String)
    case missingRenameTarget(String)

    public var errorDescription: String? {
        switch self {
        case let .missingBaseHash(path):
            return "Patch proposal is missing base hash for \(path)."
        case let .baseHashMismatch(path, expected, actual):
            return "Base hash mismatch for \(path). Expected \(expected), found \(actual)."
        case let .missingDiff(path):
            return "Unified diff is missing for \(path)."
        case let .invalidDiff(message):
            return "Invalid unified diff: \(message)"
        case let .missingNewContent(path):
            return "New file content missing for \(path)."
        case let .missingRenameTarget(path):
            return "Rename target missing for \(path)."
        }
    }
}

public struct AppliedPatchResult: Hashable, Sendable {
    public var snapshot: SnapshotRecord
    public var appliedFiles: [String]

    public init(snapshot: SnapshotRecord, appliedFiles: [String]) {
        self.snapshot = snapshot
        self.appliedFiles = appliedFiles
    }
}

public struct PatchEngine: Sendable {
    public init() {}

    public func apply(proposal: PatchProposal, workspaceID: UUID? = nil, workspaceFS: WorkspaceFS) throws -> AppliedPatchResult {
        let snapshotID = UUID()
        let snapshotRoot = workspaceFS.rootURL.appendingPathComponent(".mobiledev/snapshots/\(snapshotID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        var originalHashes: [String: String] = [:]
        var changedFiles: [String] = []

        for change in proposal.changes {
            let originalURL = try? workspaceFS.safeURL(for: change.path, requiresProtectedPathAccess: true)
            if let originalURL, FileManager.default.fileExists(atPath: originalURL.path) {
                let originalData = try Data(contentsOf: originalURL)
                originalHashes[change.path] = StableHasher.fnv1a64(data: originalData)
                let backupURL = snapshotRoot.appendingPathComponent(change.path)
                try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try originalData.write(to: backupURL)
            }

            try apply(change: change, workspaceFS: workspaceFS)
            changedFiles.append(change.newPath ?? change.path)
        }

        let snapshot = SnapshotRecord(
            workspaceID: workspaceID,
            reason: proposal.reason,
            fileHashes: originalHashes,
            changedFiles: changedFiles,
            patchID: proposal.id
        )

        return AppliedPatchResult(snapshot: snapshot, appliedFiles: changedFiles)
    }

    private func apply(change: PatchChange, workspaceFS: WorkspaceFS) throws {
        switch change.operation {
        case .modify:
            let baseHash = try require(change.baseHash, for: change.path)
            let current = try workspaceFS.readTextFile(path: change.path, allowProtectedPaths: true)
            guard current.hash == baseHash else {
                throw PatchEngineError.baseHashMismatch(path: change.path, expected: baseHash, actual: current.hash)
            }
            let diff = try require(change.diff, for: change.path, error: PatchEngineError.missingDiff(change.path))
            let updated = try applyUnifiedDiff(diff, to: current.content)
            try workspaceFS.writeTextFile(path: change.path, content: updated, allowProtectedPaths: true)

        case .create:
            let content = try require(change.newContent, for: change.path, error: PatchEngineError.missingNewContent(change.path))
            try workspaceFS.writeTextFile(path: change.path, content: content, allowProtectedPaths: true)

        case .delete:
            try workspaceFS.deleteItem(path: change.path, allowProtectedPaths: true)

        case .rename:
            let newPath = try require(change.newPath, for: change.path, error: PatchEngineError.missingRenameTarget(change.path))
            try workspaceFS.moveItem(from: change.path, to: newPath, allowProtectedPaths: true)
        }
    }

    private func require(_ value: String?, for path: String, error: Error? = nil) throws -> String {
        if let value { return value }
        if let error { throw error }
        throw PatchEngineError.missingBaseHash(path)
    }

    public func applyUnifiedDiff(_ diff: String, to original: String) throws -> String {
        let originalHasTrailingNewline = original.hasSuffix("\n")
        let originalLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diffLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var output: [String] = []
        var originalIndex = 0
        var cursor = 0

        while cursor < diffLines.count {
            let line = diffLines[cursor]
            guard line.hasPrefix("@@") else {
                cursor += 1
                continue
            }

            let header = try parseHeader(line)
            let targetIndex = max(header.originalStart - 1, 0)
            while originalIndex < targetIndex, originalIndex < originalLines.count {
                output.append(originalLines[originalIndex])
                originalIndex += 1
            }

            cursor += 1
            while cursor < diffLines.count, !diffLines[cursor].hasPrefix("@@") {
                let hunkLine = diffLines[cursor]
                guard let prefix = hunkLine.first else {
                    throw PatchEngineError.invalidDiff("Empty diff line")
                }
                let value = String(hunkLine.dropFirst())
                switch prefix {
                case " ":
                    guard originalIndex < originalLines.count, originalLines[originalIndex] == value else {
                        throw PatchEngineError.invalidDiff("Context mismatch around line \(originalIndex + 1)")
                    }
                    output.append(value)
                    originalIndex += 1
                case "-":
                    guard originalIndex < originalLines.count, originalLines[originalIndex] == value else {
                        throw PatchEngineError.invalidDiff("Removal mismatch around line \(originalIndex + 1)")
                    }
                    originalIndex += 1
                case "+":
                    output.append(value)
                case "\\":
                    break
                default:
                    throw PatchEngineError.invalidDiff("Unexpected diff prefix \(prefix)")
                }
                cursor += 1
            }
        }

        while originalIndex < originalLines.count {
            output.append(originalLines[originalIndex])
            originalIndex += 1
        }

        var result = output.joined(separator: "\n")
        if originalHasTrailingNewline || diff.contains("\n+") {
            result.append("\n")
        }
        return result
    }

    private func parseHeader(_ line: String) throws -> (originalStart: Int, updatedStart: Int) {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, range: range) else {
            throw PatchEngineError.invalidDiff("Malformed hunk header: \(line)")
        }

        func value(at index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return 1 }
            return Int(line[swiftRange]) ?? 1
        }

        return (value(at: 1), value(at: 2))
    }
}
