import Foundation
#if canImport(Compression)
import Compression
#endif

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
            return "ZIP extraction is unavailable for this archive. Only stored and deflated entries are supported on iOS."
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

        guard let enumerator = FileManager.default.enumerator(at: extractionRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return WorkspaceImportResult(items: [], warnings: ["ZIP archive was empty."])
        }

        for case let extractedURL as URL in enumerator {
            let relativePath = try extractedURL.resolvedRelativePath(from: extractionRoot)
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
        guard let enumerator = FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return WorkspaceImportResult(items: [], warnings: [])
        }
        var items: [ImportedItemResult] = []
        var warnings: [String] = []
        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = try itemURL.resolvedRelativePath(from: sourceURL)
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
        let destinationPath = try destinationURL.resolvedRelativePath(from: fs.rootURL)
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
            while counter < 10_000 {
                let name = ext.isEmpty ? "\(base)_copy_\(counter)" : "\(base)_copy_\(counter).\(ext)"
                let candidate = parent.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    _ = try candidate.resolvedRelativePath(from: fs.rootURL)
                    return candidate
                }
                counter += 1
            }
            throw WorkspaceImportError.invalidDestinationPath(relativePath)
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
        return try unzipWithSystemTool(sourceURL: sourceURL, tempRoot: tempRoot)
        #else
        return try unzipWithSwift(sourceURL: sourceURL, tempRoot: tempRoot)
        #endif
    }

    private func listZipEntries(sourceURL: URL) throws -> [String] {
        #if os(macOS) || os(Linux)
        return try listZipEntriesWithSystemTool(sourceURL: sourceURL)
        #else
        let data = try Data(contentsOf: sourceURL)
        return try parseCentralDirectory(data).map(\.path)
        #endif
    }

    #if os(macOS) || os(Linux)
    private func unzipWithSystemTool(sourceURL: URL, tempRoot: URL) throws -> URL {
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
    }

    private func listZipEntriesWithSystemTool(sourceURL: URL) throws -> [String] {
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
    }
    #endif

    private func unzipWithSwift(sourceURL: URL, tempRoot: URL) throws -> URL {
        let data = try Data(contentsOf: sourceURL)
        let entries = try parseCentralDirectory(data)
        for entry in entries {
            guard shouldImport(relativePath: entry.path) else { continue }
            let sanitized = try sanitizedRelativePath(entry.path)
            guard entry.isDirectory == false else {
                try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(sanitized, isDirectory: true), withIntermediateDirectories: true)
                continue
            }
            let payload = try readPayload(for: entry, from: data)
            let output = try decodeZipPayload(payload, method: entry.compressionMethod, uncompressedSize: Int(entry.uncompressedSize))
            let destination = tempRoot.appendingPathComponent(sanitized)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: destination, options: .atomic)
        }
        return tempRoot
    }

    private func parseCentralDirectory(_ data: Data) throws -> [ZipCentralDirectoryEntry] {
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else {
            throw WorkspaceImportError.zipExtractionFailed("End of central directory not found.")
        }
        let entryCount = Int(data.uint16LE(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))
        var offset = centralDirectoryOffset
        var entries: [ZipCentralDirectoryEntry] = []

        for _ in 0 ..< entryCount {
            guard offset + 46 <= data.count, data.uint32LE(at: offset) == 0x02014B50 else {
                throw WorkspaceImportError.zipExtractionFailed("Invalid central directory entry.")
            }
            let method = data.uint16LE(at: offset + 10)
            let compressedSize = data.uint32LE(at: offset + 20)
            let uncompressedSize = data.uint32LE(at: offset + 24)
            let fileNameLength = Int(data.uint16LE(at: offset + 28))
            let extraLength = Int(data.uint16LE(at: offset + 30))
            let commentLength = Int(data.uint16LE(at: offset + 32))
            let localHeaderOffset = data.uint32LE(at: offset + 42)
            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else {
                throw WorkspaceImportError.zipExtractionFailed("Invalid ZIP file name range.")
            }
            let path = String(decoding: data[nameStart ..< nameEnd], as: UTF8.self)
            entries.append(ZipCentralDirectoryEntry(path: path, compressionMethod: method, compressedSize: compressedSize, uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset, isDirectory: path.hasSuffix("/")))
            offset = nameEnd + extraLength + commentLength
        }
        return entries
    }

    private func findEndOfCentralDirectory(in data: Data) -> Int? {
        let signature: UInt32 = 0x06054B50
        let lowerBound = max(0, data.count - 65_557)
        guard data.count >= 22 else { return nil }
        var offset = data.count - 22
        while offset >= lowerBound {
            if data.uint32LE(at: offset) == signature { return offset }
            offset -= 1
        }
        return nil
    }

    private func readPayload(for entry: ZipCentralDirectoryEntry, from data: Data) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= data.count, data.uint32LE(at: localOffset) == 0x04034B50 else {
            throw WorkspaceImportError.zipExtractionFailed("Invalid local file header for \(entry.path).")
        }
        let fileNameLength = Int(data.uint16LE(at: localOffset + 26))
        let extraLength = Int(data.uint16LE(at: localOffset + 28))
        let dataStart = localOffset + 30 + fileNameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataStart <= data.count, dataEnd <= data.count else {
            throw WorkspaceImportError.zipExtractionFailed("Invalid ZIP payload range for \(entry.path).")
        }
        return data.subdata(in: dataStart ..< dataEnd)
    }

    private func decodeZipPayload(_ payload: Data, method: UInt16, uncompressedSize: Int) throws -> Data {
        if method == 0 { return payload }
        guard method == 8 else {
            throw WorkspaceImportError.zipExtractionUnavailable
        }
        #if canImport(Compression)
        var output = Data(count: uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { outputBuffer -> Int in
            guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { inputBuffer -> Int in
                guard let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outputBase, uncompressedSize, inputBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == uncompressedSize else {
            throw WorkspaceImportError.zipExtractionFailed("Could not inflate ZIP entry. The archive may use an unsupported deflate stream.")
        }
        output.count = decoded
        return output
        #else
        throw WorkspaceImportError.zipExtractionUnavailable
        #endif
    }
}

private struct ZipCentralDirectoryEntry {
    var path: String
    var compressionMethod: UInt16
    var compressedSize: UInt32
    var uncompressedSize: UInt32
    var localHeaderOffset: UInt32
    var isDirectory: Bool
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
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

    func resolvedRelativePath(from rootURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = standardizedFileURL.resolvingSymlinksInPath().path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw WorkspaceImportError.invalidDestinationPath(path)
        }
        guard path != rootPath else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
