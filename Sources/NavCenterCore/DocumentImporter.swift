import Foundation

public struct ImportedDocument: Codable, Equatable {
    public let sourceURL: URL
    public let originalRelativePath: String
    public let markdownRelativePath: String
    public let sourceKind: String
    public let importedAt: String
}

public final class DocumentImporter {
    private let workspaceRoot: URL
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        workspaceRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    public func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] {
        try WorkspaceManager(workspaceRoot: workspaceRoot, fileManager: fileManager).initialize()
        return try CoreFileSetCommit.serialized {
            let manifestURL = workspaceRoot.appendingPathComponent("imports/manifest.jsonl")
            try PathSafety.assertWritablePath(manifestURL, inside: workspaceRoot, label: "import manifest")
            var manifest = SQLiteSupport.exists(manifestURL) ? try PathSafety.readData(manifestURL, inside: workspaceRoot, label: "import manifest") : Data()
            if !manifest.isEmpty {
                guard let text = String(data: manifest, encoding: .utf8) else { throw NavCenterError.invalidPath("Import manifest contains invalid text.") }
                for line in text.split(separator: "\n") { _ = try JSONDecoder().decode(ImportedDocument.self, from: Data(line.utf8)) }
            }
            var reserved = Set<String>()
            var writes: [(URL, Data)] = []
            var results: [ImportedDocument] = []
            for sourceURL in urls {
                let original = try PathSafety.readData(sourceURL, inside: sourceURL.deletingLastPathComponent(), label: "source document")
                let base = sanitizedBaseName(sourceURL.deletingPathExtension().lastPathComponent)
                let kind = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension.lowercased()
                let text: String
                switch kind {
                case "txt", "md", "markdown", "yaml", "yml", "json":
                    guard let decoded = String(data: original, encoding: .utf8) else { throw NavCenterError.invalidPath("\(sourceURL.lastPathComponent) is not valid UTF-8 text. No files from this import batch were saved.") }
                    text = decoded
                default:
                    text = "Text extraction for .\(kind) is not available in this beta build. Review the retained original and add its content manually."
                }
                var index = 0
                var originalURL: URL
                var markdownURL: URL
                repeat {
                    let suffix = index == 0 ? "" : "_\(index)"
                    originalURL = workspaceRoot.appendingPathComponent("imports/originals/\(base)\(suffix).\(kind)")
                    markdownURL = workspaceRoot.appendingPathComponent("imports/markdown/\(base)\(suffix).md")
                    index += 1
                } while SQLiteSupport.exists(originalURL) || SQLiteSupport.exists(markdownURL) || reserved.contains(originalURL.path) || reserved.contains(markdownURL.path)
                reserved.insert(originalURL.path)
                reserved.insert(markdownURL.path)
                let importedAt = ISO8601DateFormatter().string(from: now())
                let markdown = markdownCopy(sourceURL: sourceURL, sourceKind: kind, importedAt: importedAt, text: text)
                let result = ImportedDocument(sourceURL: sourceURL, originalRelativePath: PathSafety.repoRelativePath(root: workspaceRoot, url: originalURL), markdownRelativePath: PathSafety.repoRelativePath(root: workspaceRoot, url: markdownURL), sourceKind: kind, importedAt: importedAt)
                writes += [(originalURL, original), (markdownURL, Data(markdown.utf8))]
                if !manifest.isEmpty && manifest.last != 10 { manifest.append(10) }
                manifest.append(try JSONEncoder().encode(result))
                results.append(result)
            }
            guard !results.isEmpty else { return [] }
            writes.append((manifestURL, manifest))
            try CoreFileSetCommit.apply(writes, inside: workspaceRoot, requireAbsent: reserved)
            return results
        }
    }

    private func markdownCopy(sourceURL: URL, sourceKind: String, importedAt: String, text: String) -> String {
        """
        ---
        source_file: \(Markdown.yamlString(sourceURL.lastPathComponent))
        source_kind: \(Markdown.yamlString(sourceKind))
        imported_at: \(Markdown.yamlString(importedAt))
        review_status: "needs-review"
        ---

        # \(sourceURL.deletingPathExtension().lastPathComponent)

        \(text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private func sanitizedBaseName(_ value: String) -> String {
        TextUtil.slugify(value).nonEmptyFallback("Imported_Document")
    }


}

private extension String {
    func nonEmptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

// Small coordinated file replacement shared by the three bounded output flows.
// Preflight and restore prior bytes on a recoverable error; it is not a crash transaction.
enum CoreFileSetCommit {
    private static let lock = NSRecursiveLock()

    static func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static func apply(_ writes: [(URL, Data)], inside root: URL, requireAbsent: Set<String> = []) throws {
        try serialized {
            let rootIdentity = try PathSafety.identity(root)
            var baseline: [String: Data] = [:]
            var identities: [String: PathSafety.Identity] = [:]
            guard Set(writes.map { $0.0.standardizedFileURL.path }).count == writes.count else { throw NavCenterError.invalidPath("Output set contains duplicate paths.") }
            for (url, _) in writes {
                if requireAbsent.contains(url.path), SQLiteSupport.exists(url) { throw NavCenterError.invalidPath("A new output target appeared before saving; existing content was preserved.") }
                try PathSafety.assertWritablePath(url, inside: root, label: "output file")
                if SQLiteSupport.exists(url) {
                    baseline[url.path] = try PathSafety.readData(url, inside: root, label: "prior output")
                    identities[url.path] = try PathSafety.identity(url)
                }
            }
            var applied: [(URL, Data)] = []
            do {
                for (url, data) in writes {
                    guard try PathSafety.identity(root) == rootIdentity else { throw NavCenterError.invalidPath("Output root changed before replacement.") }
                    if let old = baseline[url.path] {
                        guard try PathSafety.identity(url) == identities[url.path], try PathSafety.readData(url, inside: root, label: "prior output") == old else { throw NavCenterError.invalidPath("Output changed before replacement.") }
                    } else if SQLiteSupport.exists(url) { throw NavCenterError.invalidPath("Output appeared before replacement.") }
                    try PathSafety.atomicWrite(data, to: url, inside: root, label: "output file")
                    applied.append((url, data))
                }
            } catch {
                var failures: [String] = []
                for (url, data) in applied.reversed() {
                    do {
                        guard try PathSafety.identity(root) == rootIdentity, try PathSafety.readData(url, inside: root, label: "output rollback") == data else { throw NavCenterError.invalidPath("Newer output was preserved during rollback.") }
                        if let old = baseline[url.path] { try PathSafety.atomicWrite(old, to: url, inside: root, label: "output rollback") }
                        else { try PathSafety.removeFile(url, inside: root, label: "output rollback") }
                    } catch { failures.append(error.localizedDescription) }
                }
                guard failures.isEmpty else { throw NavCenterError.commandFailed("Output replacement failed; rollback needs review: \(failures.joined(separator: "; "))") }
                throw error
            }
        }
    }
}
