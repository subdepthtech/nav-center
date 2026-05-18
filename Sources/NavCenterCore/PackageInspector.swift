import Foundation

public struct PackageFile: Codable, Hashable {
    public var relativePath: String
    public var label: String
    public var kind: String
    public var format: String
    public var size: Int
    public var modifiedAt: String
    public var previewable: Bool
    public var editable: Bool
}

public struct PackageTab: Codable, Hashable {
    public var key: String
    public var label: String
    public var available: Bool
    public var fileCount: Int
    public var primaryFile: PackageFile?
    public var files: [PackageFile]
}

public struct PackageHealth: Codable, Hashable {
    public var hasPosting: Bool
    public var hasResumeSource: Bool
    public var hasCoverLetterSource: Bool
    public var hasInterviewPrep: Bool
    public var artifactCount: Int
    public var atsFileCount: Int
    public var hasAtsReport: Bool
    public var hasAtsJson: Bool
    public var previewableCount: Int
}

public struct ApplicationPackage: Codable, Hashable {
    public var name: String
    public var applicationDir: String
    public var metadata: [String: String]
    public var files: [PackageFile]
    public var tabs: [PackageTab]
    public var health: PackageHealth
}

public final class PackageInspector {
    private let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    public func scan() throws -> [ApplicationPackage] {
        let root = PathSafety.applicationsRoot(repoRoot: repoRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return []
        }
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return try inspect(packageName: entry.lastPathComponent)
        }
    }

    public func inspect(packageName: String) throws -> ApplicationPackage {
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: packageName)
        let files = try listFiles(in: resolved.packageURL)
        let posting = resolved.packageURL.appendingPathComponent("posting.md")
        let metadata: [String: String]
        if FileManager.default.fileExists(atPath: posting.path) {
            try PathSafety.assertExistingRegularFile(posting, inside: resolved.packageURL, label: "posting.md")
            metadata = Markdown.parseFrontmatter(try String(contentsOf: posting)).metadata
        } else {
            metadata = [:]
        }
        let health = buildHealth(files)
        return ApplicationPackage(
            name: resolved.packageName,
            applicationDir: PathSafety.repoRelativePath(root: repoRoot, url: resolved.packageURL),
            metadata: metadata,
            files: files,
            tabs: buildTabs(files),
            health: health
        )
    }

    private func listFiles(in packageURL: URL) throws -> [PackageFile] {
        var files: [PackageFile] = []
        let entries = try FileManager.default.contentsOfDirectory(at: packageURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                try PathSafety.assertExistingRegularFile(entry, inside: packageURL, label: "Package file")
                files.append(try fileRecord(entry, relativePath: entry.lastPathComponent))
            } else if values.isDirectory == true, entry.lastPathComponent == "artifacts" {
                try PathSafety.assertNoSymlinkSegments(entry, root: packageURL, label: "Artifacts directory")
                let artifactEntries = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                for artifact in artifactEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let artifactValues = try artifact.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if artifactValues.isRegularFile == true, artifactValues.isSymbolicLink != true {
                        try PathSafety.assertExistingRegularFile(artifact, inside: packageURL, label: "Package artifact")
                        files.append(try fileRecord(artifact, relativePath: "artifacts/\(artifact.lastPathComponent)"))
                    }
                }
            }
        }
        return files
    }

    private func fileRecord(_ url: URL, relativePath: String) throws -> PackageFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let ext = extensionFor(relativePath)
        return PackageFile(
            relativePath: relativePath,
            label: URL(fileURLWithPath: relativePath).lastPathComponent,
            kind: kindFor(relativePath),
            format: ext.isEmpty ? "file" : String(ext.dropFirst()),
            size: values.fileSize ?? 0,
            modifiedAt: ISO8601DateFormatter().string(from: values.contentModificationDate ?? Date()),
            previewable: isPreviewAllowed(relativePath) && [".md", ".txt", ".json", ".html"].contains(ext),
            editable: isEditable(relativePath)
        )
    }

    private func buildTabs(_ files: [PackageFile]) -> [PackageTab] {
        let definitions = [
            ("review", "Review"),
            ("posting", "Posting"),
            ("resume-source", "Resume Source"),
            ("notes", "Notes"),
            ("artifacts", "Artifacts"),
            ("ats", "ATS"),
            ("interview-prep", "Interview Prep")
        ]
        return definitions.map { key, label in
            let tabFiles = files.filter { belongs($0.relativePath, to: key) }.sorted { first, second in
                if key == "ats" {
                    if first.relativePath == "artifacts/ats-report.json" { return true }
                    if second.relativePath == "artifacts/ats-report.json" { return false }
                }
                return first.relativePath < second.relativePath
            }
            let primary = key == "artifacts" ? nil : tabFiles.first(where: \.previewable)
            return PackageTab(key: key, label: label, available: !tabFiles.isEmpty, fileCount: tabFiles.count, primaryFile: primary, files: tabFiles)
        }
    }
}

public func extensionFor(_ relativePath: String) -> String {
    if relativePath.hasSuffix(".docx.txt") || relativePath.hasSuffix(".pdf.txt") { return ".txt" }
    return URL(fileURLWithPath: relativePath).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: relativePath).pathExtension.lowercased())"
}

public func isPreviewAllowed(_ relativePath: String) -> Bool {
    relativePath == "posting.md"
        || relativePath == "interview-prep.md"
        || relativePath == "interview-transcript.md"
        || relativePath == "interview-review-prompt.md"
        || relativePath == "interview-review.md"
        || relativePath == "interview-realtime-session.json"
        || isPackageNoteMarkdown(relativePath)
        || relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil
        || relativePath.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) != nil
        || relativePath.range(of: #"^artifacts/[^/]+\.(md|txt|json|html)$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

public func isRawAllowed(_ relativePath: String) -> Bool {
    relativePath.range(of: #"^artifacts/Resume_[^/]+\.(pdf|html)$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

public func isEditable(_ relativePath: String) -> Bool {
    relativePath == "posting.md"
        || relativePath == "interview-prep.md"
        || relativePath == "interview-transcript.md"
        || relativePath == "interview-review-prompt.md"
        || relativePath == "interview-review.md"
        || isPackageNoteMarkdown(relativePath)
        || relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil
        || relativePath.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) != nil
}

public func kindFor(_ relativePath: String) -> String {
    if relativePath == "posting.md" { return "posting" }
    if relativePath == "interview-prep.md" { return "interview-prep" }
    if relativePath == "interview-transcript.md" { return "interview-transcript" }
    if relativePath == "interview-review-prompt.md" { return "interview-review-prompt" }
    if relativePath == "interview-review.md" { return "interview-review" }
    if relativePath == "interview-realtime-session.json" { return "interview-realtime-session" }
    if relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil { return "resume-source" }
    if relativePath.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) != nil { return "cover-letter-source" }
    if isPackageNoteMarkdown(relativePath) { return "package-note" }
    if isAtsFile(relativePath) { return "ats-artifact" }
    if relativePath.hasPrefix("artifacts/") { return "artifact" }
    return "package-file"
}

public func isAtsFile(_ relativePath: String) -> Bool {
    relativePath == "artifacts/ats-report.json" || relativePath.range(of: #"^artifacts/ats-"#, options: .regularExpression) != nil
}

public func belongs(_ relativePath: String, to tab: String) -> Bool {
    switch tab {
    case "review": return relativePath == "posting.md" || relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil || isRawAllowed(relativePath)
    case "posting": return relativePath == "posting.md"
    case "resume-source": return relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) != nil
    case "notes": return isPackageNoteMarkdown(relativePath)
    case "artifacts": return relativePath.hasPrefix("artifacts/") && !isAtsFile(relativePath)
    case "ats": return isAtsFile(relativePath)
    case "interview-prep":
        return relativePath == "interview-prep.md"
            || relativePath == "interview-transcript.md"
            || relativePath == "interview-review-prompt.md"
            || relativePath == "interview-review.md"
            || relativePath == "interview-realtime-session.json"
    default: return false
    }
}

public func isPackageNoteMarkdown(_ relativePath: String) -> Bool {
    guard !relativePath.contains("/"), extensionFor(relativePath) == ".md" else {
        return false
    }
    guard relativePath != "posting.md",
          relativePath != "interview-prep.md",
          relativePath != "interview-transcript.md",
          relativePath != "interview-review-prompt.md",
          relativePath != "interview-review.md",
          relativePath.range(of: #"^Resume_[^/]+\.md$"#, options: .regularExpression) == nil,
          relativePath.range(of: #"^CoverLetter_[^/]+\.md$"#, options: .regularExpression) == nil else {
        return false
    }
    return true
}

private func buildHealth(_ files: [PackageFile]) -> PackageHealth {
    let ats = files.filter { isAtsFile($0.relativePath) }
    return PackageHealth(
        hasPosting: files.contains { $0.relativePath == "posting.md" },
        hasResumeSource: files.contains { $0.kind == "resume-source" },
        hasCoverLetterSource: files.contains { $0.kind == "cover-letter-source" },
        hasInterviewPrep: files.contains { $0.relativePath == "interview-prep.md" },
        artifactCount: files.filter { $0.relativePath.hasPrefix("artifacts/") }.count,
        atsFileCount: ats.count,
        hasAtsReport: ats.contains { $0.relativePath == "artifacts/ats-report.json" },
        hasAtsJson: ats.contains { $0.format == "json" },
        previewableCount: files.filter(\.previewable).count
    )
}
