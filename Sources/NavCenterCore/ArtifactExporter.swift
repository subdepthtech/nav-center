import Foundation

public struct ExportedDocument: Equatable {
    public let sourceURL: URL
    public let documentType: String
    public let htmlURL: URL
    public let docxURL: URL
    public let pdfURL: URL
    public let docxTextURL: URL
    public let pdfTextURL: URL
    public let syncedApplication: VaultSyncResult?
}

public final class ArtifactExporter {
    private let repoRoot: URL
    private let environment: [String: String]

    public init(repoRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.repoRoot = repoRoot
        self.environment = environment
    }

    public func export(markdownPaths: [String]) throws -> [ExportedDocument] {
        guard !markdownPaths.isEmpty else {
            throw NavCenterError.invalidPath("Provide at least one markdown source to export.")
        }
        try ensureTool(pandocPath)
        try ensureTool(pdftotextPath, arguments: ["-v"])
        guard FileManager.default.fileExists(atPath: chromePath) else {
            throw NavCenterError.notFound("Missing Chrome binary: \(chromePath)")
        }

        var results: [ExportedDocument] = []
        for input in markdownPaths {
            results.append(try exportOne(input))
        }
        return results
    }

    private var chromePath: String {
        environment["CHROME_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    }

    private var pandocPath: String {
        environment["PANDOC_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "pandoc"
    }

    private var pdftotextPath: String {
        environment["PDFTOTEXT_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "pdftotext"
    }

    private var outputRoot: URL {
        repoRoot.appendingPathComponent("output", isDirectory: true)
    }

    private func exportOne(_ input: String) throws -> ExportedDocument {
        let source = URL(fileURLWithPath: input, relativeTo: repoRoot).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NavCenterError.notFound("Source markdown not found: \(input)")
        }
        try PathSafety.assertNoSymlinkSegments(source, root: repoRoot, label: "Source markdown")
        guard source.pathExtension.lowercased() == "md" else {
            throw NavCenterError.invalidPath("Source markdown must be a markdown file: \(input)")
        }

        let relative = PathSafety.repoRelativePath(root: repoRoot, url: source)
        let type = try documentType(relativePath: relative)
        let application = try applicationFor(relativePath: relative, inputURL: source)
        let targetDir = application?.packageURL.appendingPathComponent("artifacts", isDirectory: true) ?? outputRoot
        let writeRoot = application?.packageURL ?? repoRoot
        let base = source.deletingPathExtension().lastPathComponent
        let html = targetDir.appendingPathComponent("\(base).html")
        let docx = targetDir.appendingPathComponent("\(base).docx")
        let pdf = targetDir.appendingPathComponent("\(base).pdf")
        let docxText = URL(fileURLWithPath: "\(docx.path).txt")
        let pdfText = URL(fileURLWithPath: "\(pdf.path).txt")
        let css = repoRoot.appendingPathComponent("templates/\(type).css")

        guard FileManager.default.fileExists(atPath: css.path) else {
            throw NavCenterError.notFound("Missing CSS template for \(type): \(css.path)")
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        for output in [html, docx, pdf, docxText, pdfText] {
            try PathSafety.assertWritablePath(output, inside: writeRoot, label: "Export output")
        }

        try runOrThrow(pandocPath, [source.path, "--standalone", "--css=\(css.path)", "-o", html.path])
        var docxArgs = [source.path, "-o", docx.path]
        let reference = repoRoot.appendingPathComponent("templates/reference.docx")
        if FileManager.default.fileExists(atPath: reference.path) {
            docxArgs.insert("--reference-doc=\(reference.path)", at: 1)
        }
        try runOrThrow(pandocPath, docxArgs)
        try runOrThrow(chromePath, ["--headless=new", "--no-pdf-header-footer", "--print-to-pdf=\(pdf.path)", "file://\(html.path)"])

        let docxExtract = try captureOrThrow(pandocPath, [docx.path, "-t", "plain"])
        let pdfExtract = try captureOrThrow(pdftotextPath, ["-layout", pdf.path, "-"])
        try assertExtractedText("DOCX", docxExtract, source: docx)
        try assertExtractedText("PDF", pdfExtract, source: pdf)
        try docxExtract.write(to: docxText, atomically: true, encoding: .utf8)
        try pdfExtract.write(to: pdfText, atomically: true, encoding: .utf8)

        let synced: VaultSyncResult?
        if let application,
           environment["NAV_CENTER_SKIP_VAULT_SYNC"] != "1",
           let configuredVaultRoot = environment["NAV_CENTER_VAULT_DIR"],
           !configuredVaultRoot.isEmpty {
            let vaultRoot = URL(fileURLWithPath: configuredVaultRoot)
            if FileManager.default.fileExists(atPath: vaultRoot.path) {
                synced = try VaultSync(repoRoot: repoRoot, vaultRoot: vaultRoot).sync(applicationPath: application.packageRelativePath)
            } else {
                synced = nil
            }
        } else {
            synced = nil
        }

        return ExportedDocument(
            sourceURL: source,
            documentType: type,
            htmlURL: html,
            docxURL: docx,
            pdfURL: pdf,
            docxTextURL: docxText,
            pdfTextURL: pdfText,
            syncedApplication: synced
        )
    }

    private func documentType(relativePath: String) throws -> String {
        let base = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        if relativePath.hasPrefix("applications/") {
            if base.hasPrefix("CoverLetter_") { return "cover-letter" }
            if base.hasPrefix("Resume_") { return "resume" }
        }
        if relativePath.hasPrefix("cover-letters/") { return "cover-letter" }
        if relativePath.hasPrefix("resumes/") { return "resume" }
        throw NavCenterError.invalidPath("Source markdown must live under resumes/, cover-letters/, or applications/: \(relativePath)")
    }

    private func applicationFor(relativePath: String, inputURL: URL) throws -> (packageURL: URL, packageRelativePath: String)? {
        guard relativePath.hasPrefix("applications/") else { return nil }
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count == 3 else {
            throw NavCenterError.invalidPath("Application document must live directly under applications/<application>: \(relativePath)")
        }
        let resolved = try PathSafety.resolvePackage(root: repoRoot, packageName: parts[1])
        guard inputURL.deletingLastPathComponent().standardizedFileURL.path == resolved.packageURL.standardizedFileURL.path else {
            throw NavCenterError.invalidPath("Application document must stay inside its package: \(relativePath)")
        }
        return (resolved.packageURL, "applications/\(resolved.packageName)")
    }

    private func ensureTool(_ command: String, arguments: [String] = ["--version"]) throws {
        let result = try ProcessRunner.run(command, arguments, cwd: repoRoot)
        guard result.status == 0 else {
            throw NavCenterError.notFound("Required tool not available: \(command)")
        }
    }

    private func runOrThrow(_ command: String, _ args: [String]) throws {
        let result = try ProcessRunner.run(command, args, cwd: repoRoot)
        guard result.status == 0 else {
            throw NavCenterError.commandFailed("Command failed: \(command) \(args.joined(separator: " "))\n\(result.stderr)")
        }
    }

    private func captureOrThrow(_ command: String, _ args: [String]) throws -> String {
        let result = try ProcessRunner.run(command, args, cwd: repoRoot)
        guard result.status == 0 else {
            throw NavCenterError.commandFailed("Command failed: \(command) \(args.joined(separator: " "))\n\(result.stderr)")
        }
        return result.stdout
    }

    private func assertExtractedText(_ label: String, _ text: String, source: URL) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            throw NavCenterError.commandFailed("\(label) extraction produced too little text: \(PathSafety.repoRelativePath(root: repoRoot, url: source))")
        }
    }
}
