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
        return try urls.map(importDocument)
    }

    private func importDocument(_ sourceURL: URL) throws -> ImportedDocument {
        try PathSafety.assertExistingRegularFile(sourceURL, inside: sourceURL.deletingLastPathComponent(), label: "source document")

        let baseName = sanitizedBaseName(sourceURL.deletingPathExtension().lastPathComponent)
        let sourceKind = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension.lowercased()
        let originalName = "\(baseName).\(sourceKind)"
        let markdownName = "\(baseName).md"
        let originalURL = try uniqueURL(
            in: workspaceRoot.appendingPathComponent("imports/originals", isDirectory: true),
            preferredName: originalName
        )
        let markdownURL = try uniqueURL(
            in: workspaceRoot.appendingPathComponent("imports/markdown", isDirectory: true),
            preferredName: markdownName
        )

        try fileManager.copyItem(at: sourceURL, to: originalURL)
        let importedAt = ISO8601DateFormatter().string(from: now())
        let markdown = markdownCopy(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            importedAt: importedAt,
            text: try extractText(from: sourceURL, sourceKind: sourceKind)
        )
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let result = ImportedDocument(
            sourceURL: sourceURL,
            originalRelativePath: PathSafety.repoRelativePath(root: workspaceRoot, url: originalURL),
            markdownRelativePath: PathSafety.repoRelativePath(root: workspaceRoot, url: markdownURL),
            sourceKind: sourceKind,
            importedAt: importedAt
        )
        try appendManifest(result)
        return result
    }

    private func extractText(from url: URL, sourceKind: String) throws -> String {
        switch sourceKind {
        case "txt", "md", "markdown", "yaml", "yml", "json":
            return try String(contentsOf: url)
        default:
            return """
            Text extraction for .\(sourceKind) is not available in this beta build.

            Keep the original file for review, then paste or summarize the relevant content here before generating the master resume.
            """
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

    private func appendManifest(_ document: ImportedDocument) throws {
        let manifestURL = workspaceRoot.appendingPathComponent("imports/manifest.jsonl")
        let data = try JSONEncoder().encode(document)
        let line = String(data: data, encoding: .utf8) ?? "{}"
        if fileManager.fileExists(atPath: manifestURL.path) {
            let handle = try FileHandle(forWritingTo: manifestURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + line).utf8))
            try handle.close()
        } else {
            try line.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
    }

    private func sanitizedBaseName(_ value: String) -> String {
        TextUtil.slugify(value).nonEmptyFallback("Imported_Document")
    }

    private func uniqueURL(in directory: URL, preferredName: String) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: preferredName).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let suffix = ext.isEmpty ? "_\(index)" : "_\(index).\(ext)"
            candidate = directory.appendingPathComponent(base + suffix)
            index += 1
        }
        return candidate
    }
}

private extension String {
    func nonEmptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
