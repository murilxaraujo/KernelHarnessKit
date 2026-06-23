import Foundation

/// A workspace backed by a local directory on disk.
///
/// All paths are interpreted relative to ``rootURL`` and are validated so tools
/// cannot escape the workspace with absolute paths, `..`, symlinks, or NULs.
public actor LocalFileWorkspace: WorkspaceProvider {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public init(rootPath: String, fileManager: FileManager = .default) {
        self.init(
            rootURL: URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true),
            fileManager: fileManager
        )
    }

    public func readFile(path: String) async throws -> String {
        let url = try resolveFile(path)
        guard fileManager.fileExists(atPath: url.path) else { throw WorkspaceError.fileNotFound(path) }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            throw WorkspaceError.fileNotFound(path)
        }
    }

    public func writeFile(path: String, content: String, source: FileSource = .agent) async throws {
        let url = try resolveFile(path, allowMissingLeaf: true)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func editFile(path: String, oldString: String, newString: String) async throws {
        guard !oldString.isEmpty else { throw WorkspaceError.stringNotFound(oldString) }
        let current = try await readFile(path: path)
        let ranges = current.ranges(of: oldString)
        guard !ranges.isEmpty else { throw WorkspaceError.stringNotFound(oldString) }
        guard ranges.count == 1 else { throw WorkspaceError.stringNotUnique(oldString) }
        let updated = current.replacingOccurrences(of: oldString, with: newString)
        try await writeFile(path: path, content: updated, source: .agent)
    }

    public func listFiles() async throws -> [WorkspaceFile] {
        let root = try canonicalRoot()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [WorkspaceFile] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(from: root, to: url)
            if shouldSkip(relativePath: relative, url: url) {
                if isDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(WorkspaceFile(
                path: relative,
                sizeBytes: Int64(values.fileSize ?? 0),
                source: .upload,
                updatedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    public func deleteFile(path: String) async throws {
        let url = try resolveFile(path)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func fileExists(path: String) async throws -> Bool {
        let url = try resolveFile(path)
        return fileManager.fileExists(atPath: url.path)
    }

    private func resolveFile(_ path: String, allowMissingLeaf: Bool = false) throws -> URL {
        guard isSafeRelativePath(path) else { throw WorkspaceError.invalidPath(path) }
        let root = try canonicalRoot()
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        let canonicalParent = try canonicalExistingDirectory(parent, originalPath: path)
        let resolved = canonicalParent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        guard isDescendant(resolved, of: root) else { throw WorkspaceError.invalidPath(path) }
        if !allowMissingLeaf, isSymlink(resolved) { throw WorkspaceError.invalidPath(path) }
        return resolved
    }

    private func canonicalRoot() throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.invalidPath(rootURL.path)
        }
        return rootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func canonicalExistingDirectory(_ url: URL, originalPath: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Walk up to the nearest existing parent for writes creating new directories.
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { throw WorkspaceError.invalidPath(originalPath) }
            return try canonicalExistingDirectory(parent, originalPath: originalPath)
                .appendingPathComponent(url.lastPathComponent)
                .standardizedFileURL
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == path else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.contains("\0") { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func shouldSkip(relativePath: String, url: URL) -> Bool {
        let blocked = [".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData"]
        return relativePath.split(separator: "/").contains { blocked.contains(String($0)) }
            || isSymlink(url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func relativePath(from root: URL, to url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return String(url.path.dropFirst(rootPath.count))
    }
}

private extension String {
    func ranges(of string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = self[searchStart...].range(of: string) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}
