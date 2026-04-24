import Foundation

public enum WorkspaceImportError: Error, LocalizedError {
    case invalidSourceURL(URL)
    case invalidDestinationPath(String)
    case zipExtractionUnavailable
    case zipExtractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSourceURL(url):
            return "Cannot import from source URL: \(url.path)."
        case let .invalidDestinationPath(path):
            return "Import destination path is invalid: \(path)."
        case .zipExtractionUnavailable:
            return "ZIP extraction is unavailable on this platform."
        case let .zipExtractionFailed(message):
            return "ZIP extraction failed: \(message)"
        }
    }
}

public struct WorkspaceImportService: Sendable {
    public let workspaceManager: WorkspaceManager

    public init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    public func importSingleFile(
        sourceURL: URL,
        workspaceID: UUID,
        destinationPath: String? = nil,
        conflictPolicy: ImportConflictPolicy = .keepBoth
    ) throws -> WorkspaceImportResult {
        try importFiles(sourceURLs: [sourceURL], workspaceID: workspaceID, destinationRoot: destinationPath, conflictPolicy: conflictPolicy)
    }

    public func importFiles(
        sourceURLs: [URL],
        workspaceID: UUID,
        destinationRoot: String? = nil,
        conflictPolicy: ImportConflictPolicy = .keepBoth
    ) throws -> WorkspaceImportResult {
        let workspace = try workspaceManager.loadWorkspace(id: workspaceID)
        let fs = try workspaceManager.workspaceFS(for: workspace)
        var items: [ImportedItemResult] = []
        var warnings: [String] = []

        for sourceURL in sourceURLs {
            let scoped = sourceURL.startAccessingSecurityScopedResourceIfAvailable
            defer {
                if scoped { sourceURL.stopAccessingSecurityScopedResourceIfAvailable() }
            }

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                items.append(ImportedItemResult(sourcePath: sourceURL.path, status: .skipped, message: WorkspaceImportError.invalidSourceURL(sourceURL).localizedDescription))
                continue
            }

            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let result = try copyDirectory(sourceURL: sourceURL, destinationRoot: destinationRoot, fs: fs, conflictPolicy: conflictPolicy)
                items.append(contentsOf: result.items)
                warnings.append(contentsOf: result.warnings)
            } else {
                let relativeName = destinationRoot.flatMap { root in
                    root.isEmpty ? nil : root + "/" + sourceURL.lastPathComponent
                } ?? sourceURL.lastPathComponent
                let copied = try copyItem(sourceURL: sourceURL, relativeDestinationPath: relativeName, fs: fs, conflictPolicy: conflictPolicy)
                items.append(copied)
                if copied.status == .duplicated {
                    warnings.append("Imported duplicate as \(copied.destinationPath ?? relativeName).")
                }
            }
        }

        return WorkspaceImportResult(items: items, warnings: warnings)
    }

    public func importDirectory(
        sourceURLs: [URL],
        workspaceID: UUID,
        conflictPolicy: ImportConflictPolicy = .keepBoth
    ) throws -> WorkspaceImportResult {
        try importFiles(sourceURLs: sourceURLs, workspaceID: workspaceID, destinationRoot: nil, conflictPolicy: conflictPolicy)
    }

    public func importZip(
        sourceURL: URL,
        workspaceID: UUID,
        conflictPolicy: ImportConflictPolicy = .keepBoth
    ) throws -> WorkspaceImportResult {
        let listedEntries = try listZipEntries(sourceURL: sourceURL)
        for entry in listedEntries where shouldImport(relativePath: entry) {
            _ = try sanitizedRelativePath(entry)
        }
        let extractionRoot = try unzipToTemporaryDirectory(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: extractionRoot) }
        let workspace = try workspaceManager.loadWorkspace(id: workspaceID)
        let fs = try workspaceManager.workspaceFS(for: workspace)
        var items: [ImportedItemResult] = []
        var warnings: [String] = []

        guard let enumerator = FileManager.default.enumerator(at: extractionRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return WorkspaceImportResult(items: [], warnings: ["ZIP archive was empty."])
        }

        for case let extractedURL as URL in enumerator {
            let relativePath = extractedURL.path.replacingOccurrences(of: extractionRoot.path + "/", with: "")
            guard shouldImport(relativePath: relativePath) else {
                items.append(ImportedItemResult(sourcePath: relativePath, status: .skipped, message: "Ignored by import rules."))
                continue
            }
            let values = try extractedURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let copied = try copyItem(sourceURL: extractedURL, relativeDestinationPath: relativePath, fs: fs, conflictPolicy: conflictPolicy)
            items.append(copied)
            if copied.status == .duplicated {
                warnings.append("Imported duplicate as \(copied.destinationPath ?? relativePath).")
            }
        }

        return WorkspaceImportResult(items: items, warnings: warnings)
    }

    private func copyDirectory(sourceURL: URL, destinationRoot: String?, fs: WorkspaceFS, conflictPolicy: ImportConflictPolicy) throws -> WorkspaceImportResult {
        guard let enumerator = FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return WorkspaceImportResult(items: [], warnings: [])
        }
        var items: [ImportedItemResult] = []
        var warnings: [String] = []
        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = itemURL.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
            guard shouldImport(relativePath: relativePath) else {
                items.append(ImportedItemResult(sourcePath: relativePath, status: .skipped, message: "Ignored by import rules."))
                continue
            }
            if values.isDirectory == true { continue }
            let target = [destinationRoot, sourceURL.lastPathComponent, relativePath]
                .compactMap { value in
                    guard let value, value.isEmpty == false else { return nil }
                    return value
                }
                .joined(separator: "/")
            let copied = try copyItem(sourceURL: itemURL, relativeDestinationPath: target, fs: fs, conflictPolicy: conflictPolicy)
            items.append(copied)
            if copied.status == .duplicated {
                warnings.append("Imported duplicate as \(copied.destinationPath ?? target).")
            }
        }
        return WorkspaceImportResult(items: items, warnings: warnings)
    }

    private func copyItem(sourceURL: URL, relativeDestinationPath: String, fs: WorkspaceFS, conflictPolicy: ImportConflictPolicy) throws -> ImportedItemResult {
        let sanitizedPath = try sanitizedRelativePath(relativeDestinationPath)
        let destinationURL = try resolvedDestinationURL(for: sanitizedPath, fs: fs, conflictPolicy: conflictPolicy)
        let destinationPath = destinationURL.path.replacingOccurrences(of: fs.rootURL.path + "/", with: "")
        let existed = FileManager.default.fileExists(atPath: destinationURL.path)

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existed {
            switch conflictPolicy {
            case .overwrite:
                try FileManager.default.removeItem(at: destinationURL)
            case .keepBoth:
                break
            case .cancel:
                return ImportedItemResult(sourcePath: sourceURL.path, destinationPath: sanitizedPath, status: .skipped, message: "Destination already exists.")
            }
        }
        let preferredPath = try fs.safeURL(for: sanitizedPath).path
        if !existed || conflictPolicy == .overwrite || destinationURL.path != preferredPath {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        let status: ImportedItemStatus
        if destinationPath != sanitizedPath {
            status = .duplicated
        } else if existed, conflictPolicy == .overwrite {
            status = .overwritten
        } else {
            status = .imported
        }
        return ImportedItemResult(sourcePath: sourceURL.path, destinationPath: destinationPath, status: status)
    }

    private func resolvedDestinationURL(for relativePath: String, fs: WorkspaceFS, conflictPolicy: ImportConflictPolicy) throws -> URL {
        let preferredURL = try fs.safeURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }
        switch conflictPolicy {
        case .overwrite, .cancel:
            return preferredURL
        case .keepBoth:
            let base = preferredURL.deletingPathExtension().lastPathComponent
            let ext = preferredURL.pathExtension
            let parent = preferredURL.deletingLastPathComponent()
            var counter = 2
            while true {
                let name = ext.isEmpty ? "\(base)_copy_\(counter)" : "\(base)_copy_\(counter).\(ext)"
                let candidate = parent.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    guard candidate.path == fs.rootURL.path || candidate.path.hasPrefix(fs.rootURL.path + "/") else {
                        throw WorkspaceImportError.invalidDestinationPath(relativePath)
                    }
                    return candidate
                }
                counter += 1
            }
        }
    }

    private func sanitizedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\") else {
            throw WorkspaceImportError.invalidDestinationPath(path)
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.contains("..") == false else {
            throw WorkspaceImportError.invalidDestinationPath(path)
        }
        let filtered = parts.filter { $0.isEmpty == false }
        guard filtered.isEmpty == false else {
            throw WorkspaceImportError.invalidDestinationPath(path)
        }
        return filtered.joined(separator: "/")
    }

    private func shouldImport(relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts.contains("__MACOSX") { return false }
        if parts.last == ".DS_Store" { return false }
        return true
    }

    private func unzipToTemporaryDirectory(sourceURL: URL) throws -> URL {
        let scoped = sourceURL.startAccessingSecurityScopedResourceIfAvailable
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResourceIfAvailable() }
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", sourceURL.path, "-d", tempRoot.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            throw WorkspaceImportError.zipExtractionFailed(String(decoding: data, as: UTF8.self))
        }
        return tempRoot
        #else
        throw WorkspaceImportError.zipExtractionUnavailable
        #endif
    }

    private func listZipEntries(sourceURL: URL) throws -> [String] {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", sourceURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            throw WorkspaceImportError.zipExtractionFailed(String(decoding: data, as: UTF8.self))
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #else
        throw WorkspaceImportError.zipExtractionUnavailable
        #endif
    }
}

private extension URL {
    var startAccessingSecurityScopedResourceIfAvailable: Bool {
        #if canImport(UIKit)
        return startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    func stopAccessingSecurityScopedResourceIfAvailable() {
        #if canImport(UIKit)
        stopAccessingSecurityScopedResource()
        #endif
    }
}
