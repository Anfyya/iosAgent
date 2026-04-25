import Foundation

public enum WorkspaceFSError: Error, LocalizedError {
    case invalidRoot
    case emptyPath
    case absolutePath
    case pathTraversal
    case outsideWorkspace
    case symlinkEscape(String)
    case protectedPath(String)
    case binaryFile(String)
    case fileTooLarge(String)
    case missingFile(String)
    case targetIsDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Workspace root is invalid."
        case .emptyPath:
            return "Empty paths are not allowed for this operation."
        case .absolutePath:
            return "Absolute paths are not allowed."
        case .pathTraversal:
            return "Path traversal is not allowed."
        case .outsideWorkspace:
            return "Resolved path points outside the workspace."
        case let .symlinkEscape(path):
            return "Symlink escapes the workspace boundary: \(path)"
        case let .protectedPath(path):
            return "Protected path requires confirmation: \(path)"
        case let .binaryFile(path):
            return "Binary files are not supported by the text toolchain: \(path)"
        case let .fileTooLarge(path):
            return "File is too large for inline context: \(path)"
        case let .missingFile(path):
            return "File does not exist: \(path)"
        case let .targetIsDirectory(path):
            return "Cannot save a file at a folder path: \(path)"
        }
    }
}

public struct WorkspaceFS: Sendable {
    public let rootURL: URL
    public let maxInlineFileSize: Int
    public let protectedPathPrefixes: [String]

    public init(rootURL: URL, maxInlineFileSize: Int = 256_000, protectedPathPrefixes: [String] = [".mobiledev/cache", ".mobiledev/provider_profiles", ".github/workflows"]) throws {
        let normalizedRoot = rootURL.standardizedFileURL
        guard normalizedRoot.isFileURL else { throw WorkspaceFSError.invalidRoot }
        self.rootURL = normalizedRoot
        self.maxInlineFileSize = maxInlineFileSize
        self.protectedPathPrefixes = protectedPathPrefixes
    }

    public func safeURL(for path: String, requiresProtectedPathAccess: Bool = false, allowWorkspaceRoot: Bool = false) throws -> URL {
        let normalizedInput = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.hasPrefix("/") else { throw WorkspaceFSError.absolutePath }
        // Tool payloads are user/model generated, so reject backslashes up front instead of
        // trying to interpret mixed separator styles inside the iOS workspace sandbox.
        guard !normalizedInput.contains("\\") else { throw WorkspaceFSError.pathTraversal }
        let pathParts = normalizedInput.split(separator: "/").map(String.init)
        guard !pathParts.contains(".."), !pathParts.contains(".") else { throw WorkspaceFSError.pathTraversal }

        let trimmedPath = normalizedInput.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            if allowWorkspaceRoot {
                return rootURL
            }
            throw WorkspaceFSError.emptyPath
        }
        let candidate = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        guard isWithinRoot(candidate) else { throw WorkspaceFSError.outsideWorkspace }
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isWithinRoot(resolvedCandidate) else { throw WorkspaceFSError.symlinkEscape(trimmedPath) }

        if !requiresProtectedPathAccess,
           protectedPathPrefixes.contains(where: { trimmedPath == $0 || trimmedPath.hasPrefix($0 + "/") }) {
            throw WorkspaceFSError.protectedPath(trimmedPath)
        }

        return resolvedCandidate
    }

    public func listFiles() throws -> [WorkspaceFileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys) else {
            throw WorkspaceFSError.invalidRoot
        }

        var entries: [WorkspaceFileEntry] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            let relativePath = try relativePath(for: fileURL)
            entries.append(
                WorkspaceFileEntry(
                    path: relativePath,
                    isDirectory: values.isDirectory ?? false,
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }

        return entries.sorted { $0.path < $1.path }
    }

    public func readTextFile(path: String, allowProtectedPaths: Bool = false) throws -> ReadFileResult {
        let url = try safeURL(for: path, requiresProtectedPathAccess: allowProtectedPaths)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceFSError.missingFile(path) }

        let data = try Data(contentsOf: url)
        guard data.count <= maxInlineFileSize else { throw WorkspaceFSError.fileTooLarge(path) }
        guard !isBinary(data: data) else { throw WorkspaceFSError.binaryFile(path) }

        let content = String(decoding: data, as: UTF8.self)
        return ReadFileResult(path: path, content: content, hash: StableHasher.fnv1a64(data: data))
    }

    public func search(query: String, caseSensitive: Bool = false, limit: Int = 50) throws -> [SearchMatch] {
        let entries = try listFiles().filter { !$0.isDirectory }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [SearchMatch] = []

        for entry in entries {
            guard matches.count < limit else { break }
            guard let result = try? readTextFile(path: entry.path) else { continue }
            for (index, line) in result.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard matches.count < limit else { break }
                if line.range(of: query, options: options) != nil {
                    matches.append(SearchMatch(path: entry.path, lineNumber: index + 1, line: String(line)))
                }
            }
        }

        return matches
    }

    public func writeTextFile(path: String, content: String, allowProtectedPaths: Bool = false) throws {
        let url = try safeURL(for: path, requiresProtectedPathAccess: allowProtectedPaths)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw WorkspaceFSError.targetIsDirectory(path)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
    }

    public func deleteItem(path: String, allowProtectedPaths: Bool = false) throws {
        let url = try safeURL(for: path, requiresProtectedPathAccess: allowProtectedPaths)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceFSError.missingFile(path) }
        try FileManager.default.removeItem(at: url)
    }

    public func moveItem(from source: String, to destination: String, allowProtectedPaths: Bool = false) throws {
        let sourceURL = try safeURL(for: source, requiresProtectedPathAccess: allowProtectedPaths)
        let destinationURL = try safeURL(for: destination, requiresProtectedPathAccess: allowProtectedPaths)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    public func hashForFile(at path: String, allowProtectedPaths: Bool = false) throws -> String {
        let url = try safeURL(for: path, requiresProtectedPathAccess: allowProtectedPaths)
        let data = try Data(contentsOf: url)
        return StableHasher.fnv1a64(data: data)
    }

    private func isBinary(data: Data) -> Bool {
        data.prefix(512).contains(0)
    }

    private func relativePath(for fileURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            throw WorkspaceFSError.outsideWorkspace
        }
        guard filePath != rootPath else { return "" }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func isWithinRoot(_ candidate: URL) -> Bool {
        let candidatePaths = [
            candidate.standardizedFileURL.path,
            candidate.standardizedFileURL.resolvingSymlinksInPath().path
        ]
        let rootPaths = [
            rootURL.standardizedFileURL.path,
            rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        ]
        return candidatePaths.contains { candidatePath in
            rootPaths.contains { rootPath in
                candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
            }
        }
    }
}
