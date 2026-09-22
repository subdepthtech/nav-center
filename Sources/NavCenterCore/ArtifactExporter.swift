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
    public var warnings: [String] = []
}

public final class ArtifactExporter {
    private struct ResolvedTools {
        let pandoc: String
        let pdftotext: String
        let chrome: String
    }

    private let repoRoot: URL
    private let environment: [String: String]
    private let toolProbe: ToolProbeConfiguration

    public init(repoRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment, toolProbe: ToolProbeConfiguration? = nil) {
        self.repoRoot = repoRoot
        self.environment = environment
        self.toolProbe = toolProbe ?? ToolProbeConfiguration(environment: environment)
    }

    public func export(markdownPaths: [String]) throws -> [ExportedDocument] {
        guard !markdownPaths.isEmpty else {
            throw NavCenterError.invalidPath("Provide at least one markdown source to export.")
        }
        let tools = ResolvedTools(
            pandoc: try resolvedExecutable(.pandoc),
            pdftotext: try resolvedExecutable(.pdftotext),
            chrome: try resolvedExecutable(.chrome)
        )
        try ensureTool(tools.pandoc)
        try ensureTool(tools.pdftotext, arguments: ["-v"])

        var results: [ExportedDocument] = []
        for input in markdownPaths {
            do { results.append(try exportOne(input, tools: tools)) }
            catch { throw ArtifactExportBatchError(completed: results, failedInput: input, reason: error.localizedDescription) }
        }
        return results
    }

    private func resolvedExecutable(_ tool: ExternalTool) throws -> String {
        let status = ToolProbe.resolve(tool, configuration: toolProbe)
        guard status.state == .found, let path = status.resolvedPath else {
            throw NavCenterError.notFound(ToolProbe.missingToolMessage(status, action: "Document export"))
        }
        return path
    }

    private var outputRoot: URL {
        repoRoot.appendingPathComponent("output", isDirectory: true)
    }

    private func exportOne(_ input: String, tools: ResolvedTools) throws -> ExportedDocument {
        let source = (input.hasPrefix("/") ? URL(fileURLWithPath: input) : repoRoot.appendingPathComponent(input)).standardizedFileURL
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
        let sourceData = try PathSafety.readData(source, inside: repoRoot, label: "Export markdown", maxBytes: 256 * 1024)
        let cssData = try PathSafety.readData(css, inside: repoRoot, label: "Export stylesheet", maxBytes: 64 * 1024)
        guard String(data: sourceData, encoding: .utf8) != nil, let stylesheet = String(data: cssData, encoding: .utf8) else {
            throw NavCenterError.commandFailed("Export markdown and stylesheet must use UTF-8 encoding.")
        }
        try InertDocumentRenderer.validateCSS(stylesheet)
        let outputs = [html, docx, pdf, docxText, pdfText]
        for output in outputs { try PathSafety.assertWritablePath(output, inside: writeRoot, label: "Export output") }
        let rootIdentity = try PathSafety.identity(writeRoot)
        var prior: [String: Data] = [:]
        for output in outputs where SQLiteSupport.exists(output) { prior[output.path] = try PathSafety.readData(output, inside: writeRoot, label: "prior export") }
        let staging = writeRoot.appendingPathComponent(".nav-center-export-\(UUID().uuidString)", isDirectory: true)
        try PathSafety.createDirectory(staging, inside: writeRoot, label: "export staging")
        let stagingIdentity = try PathSafety.identity(staging)
        defer {
            if (try? PathSafety.identity(staging)) == stagingIdentity,
               (try? PathSafety.identity(writeRoot)) == rootIdentity,
               (try? FileManager.default.contentsOfDirectory(atPath: staging.path).contains(where: { $0.hasPrefix("chrome-profile-") })) == false {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        let staged = outputs.map { staging.appendingPathComponent($0.lastPathComponent) }
        let capturedSource = staging.appendingPathComponent("source.md")
        try PathSafety.atomicWrite(sourceData, to: capturedSource, inside: staging, label: "Captured export source")
        let reference = repoRoot.appendingPathComponent("templates/reference.docx")
        var capturedReference: URL?
        if FileManager.default.fileExists(atPath: reference.path) {
            let captured = staging.appendingPathComponent("reference.docx")
            let referenceData = try PathSafety.readData(reference, inside: repoRoot, label: "Reference DOCX", maxBytes: 8 * 1024 * 1024)
            try PathSafety.atomicWrite(referenceData, to: captured, inside: staging, label: "Captured reference DOCX")
            capturedReference = captured
        }
        // A fragment avoids user/default standalone templates and their active resources.
        // --sandbox is required: older Pandoc versions must fail rather than read includes.
        try runOrThrow(tools.pandoc, [capturedSource.path, "--sandbox", "--from=markdown", "--to=html4", "-o", staged[0].path])
        let fragmentData = try PathSafety.readData(staged[0], inside: staging, label: "Export HTML fragment", maxBytes: 256 * 1024)
        guard let fragment = String(data: fragmentData, encoding: .utf8) else { throw NavCenterError.commandFailed("Pandoc HTML must use UTF-8 encoding.") }
        let document = try InertDocumentRenderer.document(fragment: fragment, css: stylesheet)
        try PathSafety.atomicWrite(Data(document.utf8), to: staged[0], inside: staging, label: "Inert export HTML")
        var docxArgs = [capturedSource.path, "--sandbox", "--from=markdown", "-o", staged[1].path]
        if let capturedReference {
            docxArgs.insert("--reference-doc=\(capturedReference.path)", at: 1)
        }
        try runOrThrow(tools.pandoc, docxArgs)
        try InertDocumentRenderer.render(document: document, pdfURL: staged[2], staging: staging, chromePath: tools.chrome)
        let htmlData = try PathSafety.readData(staged[0], inside: staging, label: "export HTML")
        let docxData = try PathSafety.readData(staged[1], inside: staging, label: "export DOCX")
        let pdfData = try PathSafety.readData(staged[2], inside: staging, label: "export PDF")
        guard !htmlData.isEmpty, docxData.starts(with: Data("PK".utf8)), pdfData.starts(with: Data("%PDF-".utf8)) else { throw NavCenterError.commandFailed("Export did not produce the expected HTML, DOCX, and PDF formats.") }
        let docxExtract = try captureOrThrow(tools.pandoc, [staged[1].path, "--sandbox", "-t", "plain"])
        let pdfExtract = try captureOrThrow(tools.pdftotext, ["-layout", staged[2].path, "-"])
        try assertExtractedText("DOCX", docxExtract, source: docx)
        try assertExtractedText("PDF", pdfExtract, source: pdf)
        guard try PathSafety.identity(writeRoot) == rootIdentity else { throw NavCenterError.invalidPath("Export output root changed during conversion.") }
        for output in outputs {
            let current = SQLiteSupport.exists(output) ? try PathSafety.readData(output, inside: writeRoot, label: "prior export") : nil
            guard current == prior[output.path] else { throw NavCenterError.invalidPath("Export outputs changed during conversion; newer artifacts were preserved.") }
        }
        try CoreFileSetCommit.apply(Array(zip(outputs, [htmlData, docxData, pdfData, Data(docxExtract.utf8), Data(pdfExtract.utf8)])), inside: writeRoot)

        var synced: VaultSyncResult?
        var warnings: [String] = []
        if let application,
           environment["NAV_CENTER_SKIP_VAULT_SYNC"] != "1",
           let configuredVaultRoot = environment["NAV_CENTER_VAULT_DIR"],
           !configuredVaultRoot.isEmpty {
            let vaultRoot = URL(fileURLWithPath: configuredVaultRoot)
            if FileManager.default.fileExists(atPath: vaultRoot.path) {
                do { synced = try VaultSync(repoRoot: repoRoot, vaultRoot: vaultRoot).sync(applicationPath: application.packageRelativePath) }
                catch { warnings.append("Export artifacts were committed, but the vault copy failed: \(error.localizedDescription)") }
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
            syncedApplication: synced,
            warnings: warnings
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

// This is deliberately a document subset, not a general-purpose HTML sanitizer.
// Parse XHTML, reject unsupported features, and serialize only approved syntax;
// never give Chrome the original HTML or a file:// document origin.
enum InertDocumentRenderer {
    static func document(fragment: String, css: String) throws -> String {
        guard fragment.utf8.count <= 256 * 1024 else { throw unsupported("HTML larger than 256 KiB") }
        try validateCSS(css)
        guard !fragment.contains("<!"), !fragment.contains("<?") else { throw unsupported("HTML declarations, comments or processing instructions") }
        let delegate = InertHTMLParser()
        let parser = XMLParser(data: Data(("<navcenter>" + fragment + "</navcenter>").utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? unsupported("HTML that is not well-formed XHTML; remove raw HTML or use a supported Pandoc version")
        }
        let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        let document = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><title>Application document</title><style>\(css)</style></head><body>\(delegate.output)</body></html>"
        guard document.utf8.count <= 256 * 1024 else { throw unsupported("HTML larger than 256 KiB") }
        return document
    }

    static func validateCSS(_ css: String) throws {
        guard css.utf8.count <= 64 * 1024 else { throw unsupported("stylesheets larger than 64 KiB") }
        // Reject escapes and comments outright, rather than trying to normalize
        // CSS tokenization tricks such as u\\72l or u/**/rl.
        guard !css.contains("\\"), !css.contains("/*"), !css.contains("*/"), !css.contains("<"),
              !css.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            throw unsupported("CSS escapes, comments, markup or control characters")
        }
        let rules = try NSRegularExpression(pattern: #"@\s*([\p{L}_-]+)"#)
        let functions = try NSRegularExpression(pattern: #"([\p{L}_-][\p{L}\p{N}_-]*)\("#)
        let spacedFunctions = try NSRegularExpression(pattern: #"([\p{L}_-][\p{L}\p{N}_-]*)\s+\("#)
        let allowedPrelude = try NSRegularExpression(pattern: #"^\s*@\s*(?:page|media)(?=\s|:|\()"#, options: .caseInsensitive)
        let declaration = try NSRegularExpression(pattern: #"^\s*(?:[A-Za-z_-]|[^\x00-\x7F])(?:[A-Za-z0-9_-]|[^\x00-\x7F])*\s*:"#)
        let range = NSRange(css.startIndex..<css.endIndex, in: css)
        for match in rules.matches(in: css, range: range) {
            let name = (css as NSString).substring(with: match.range(at: 1)).lowercased()
            guard ["page", "media"].contains(name) else { throw unsupported("CSS @\(name.prefix(32)) rules") }
        }
        let allowedFunctions: Set<String> = ["rgb", "rgba", "hsl", "hsla", "calc", "min", "max", "clamp", "not", "nth-child", "nth-of-type", "is", "where", "counter", "counters"]
        for match in functions.matches(in: css, range: range) {
            let name = (css as NSString).substring(with: match.range(at: 1)).lowercased()
            guard allowedFunctions.contains(name) else { throw unsupported("CSS function \(name.prefix(32))()") }
        }
        // Function tokens require an immediately adjacent '('. Still reject
        // legacy whitespace-tolerant spellings outside allowed at-rule preludes,
        // including bare declaration lists supplied by inline style attributes.
        func validateStatement(_ statement: Substring, opensBlock: Bool) throws {
            let text = String(statement)
            let statementRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if opensBlock, allowedPrelude.firstMatch(in: text, range: statementRange) != nil { return }
            for match in spacedFunctions.matches(in: text, range: statementRange) {
                let name = (text as NSString).substring(with: match.range(at: 1)).lowercased()
                guard allowedFunctions.contains(name) else { throw unsupported("CSS function \(name.prefix(32))()") }
            }
        }
        // Only real statement boundaries can introduce a prelude. Quotes and
        // component blocks must not let declaration values manufacture one.
        var start = css.startIndex
        var quote: Unicode.Scalar?
        var closers: [Unicode.Scalar] = []
        for index in css.unicodeScalars.indices {
            let character = css.unicodeScalars[index]
            if let currentQuote = quote {
                if character == currentQuote || character == "\n" || character == "\r" { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { closers.append(")"); continue }
            if character == "[" { closers.append("]"); continue }
            if character == "{" {
                if !closers.isEmpty { closers.append("}"); continue }
                let statement = String(css[start..<index])
                let statementRange = NSRange(statement.startIndex..<statement.endIndex, in: statement)
                // Keep curly component blocks in declaration values together.
                // Ambiguous pseudo-selectors are conservatively checked as a unit.
                if declaration.firstMatch(in: statement, range: statementRange) != nil {
                    closers.append("}")
                    continue
                }
            }
            if character == closers.last { closers.removeLast(); continue }
            guard closers.isEmpty, character == "{" || character == "}" || character == ";" else { continue }
            try validateStatement(css[start..<index], opensBlock: character == "{")
            start = css.unicodeScalars.index(after: index)
        }
        try validateStatement(css[start...], opensBlock: false)
    }

    static func render(document: String, pdfURL: URL, staging: URL, chromePath: String) throws {
        // The only production caller supplies the output of document(fragment:css:).
        let profile = staging.appendingPathComponent("chrome-profile-\(UUID().uuidString)", isDirectory: true)
        try PathSafety.createDirectory(profile, inside: staging, label: "Private renderer profile")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        let profileIdentity = try PathSafety.identity(profile)
        var rendererStopped = false
        defer { if rendererStopped, (try? PathSafety.identity(profile)) == profileIdentity { try? FileManager.default.removeItem(at: profile) } }
        let args = chromeArguments(document: document, pdfURL: pdfURL, profile: profile)
        var completedPDF = false
        let status: Int32
        do {
            status = try ProcessRunner.run(chromePath, args, cwd: staging, timeout: 60, isCancelled: {
                // Some Chrome releases keep their browser process alive after
                // printing. Stop this dedicated process group only after the
                // complete PDF trailer is present, then validate the artifact.
                guard let data = try? PathSafety.readData(pdfURL, inside: staging, label: "Rendered PDF"),
                      data.starts(with: Data("%PDF-".utf8)),
                      let tail = String(data: data.suffix(32), encoding: .ascii),
                      tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%%EOF") else { return false }
                completedPDF = true
                return true
            }).status
        } catch NavCenterError.commandFailed("Process cancelled.") where completedPDF {
            status = 0
        } catch {
            try verifyShutdown(profile: profile, staging: staging)
            rendererStopped = true
            throw error
        }
        try verifyShutdown(profile: profile, staging: staging)
        rendererStopped = true
        guard status == 0 else {
            // Do not include the data URL (which contains the resume) in errors.
            throw NavCenterError.commandFailed("Chrome could not render the isolated document. Its built-in sandbox must remain enabled; check the Chrome installation and try again.")
        }
        let pdf = try PathSafety.readData(pdfURL, inside: staging, label: "Rendered PDF")
        guard pdf.starts(with: Data("%PDF-".utf8)) else { throw NavCenterError.commandFailed("Chrome did not produce a PDF document.") }
    }

    private static func verifyShutdown(profile: URL, staging: URL) throws {
        // Check only the unique renderer profile; never signal or inspect the
        // contents of a user's ordinary Chrome profile.
        let pattern = NSRegularExpression.escapedPattern(for: profile.path)
        for _ in 0..<10 {
            let result = try ProcessRunner.run("/usr/bin/pgrep", ["-f", pattern], cwd: staging, timeout: 2, maximumOutputBytes: 4096)
            if result.status == 1 { return }
            guard result.status == 0 else { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NavCenterError.commandFailed("Chrome renderer shutdown could not be verified. Private temporary render data has been retained; close the renderer before retrying export.")
    }

    static func chromeArguments(document: String, pdfURL: URL, profile: URL) -> [String] {
        ["--headless=new", "--no-pdf-header-footer", "--print-to-pdf=\(pdfURL.path)",
         "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
         "--disable-extensions", "--disable-sync", "--disable-background-networking",
         "--disable-component-update", "--disable-domain-reliability", "--disable-client-side-phishing-detection",
         "--disable-breakpad", "--metrics-recording-only", "--disable-quic",
         "--proxy-server=http://127.0.0.1:9", "--proxy-bypass-list=<-loopback>",
         // Disabling JavaScript globally also disables Chrome's own headless
         // print command. Document scripts are rejected and prohibited by CSP.
         "--host-resolver-rules=MAP * ~NOTFOUND",
         "data:text/html;charset=utf-8;base64," + Data(document.utf8).base64EncodedString()]
    }

    static func unsupported(_ feature: String) -> NavCenterError {
        .commandFailed("Document export does not support \(feature). Use text, headings, lists, tables and local styling; scripts, embedded resources and automatic navigation are not supported.")
    }

    fileprivate static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class InertHTMLParser: NSObject, XMLParserDelegate {
    var output = ""
    var failure: Error?
    private var depth = 0
    private var elements = 0
    private let tags: Set<String> = ["html", "p", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "strong", "em", "b", "i", "u", "s", "del", "sup", "sub", "small", "blockquote", "pre", "code", "br", "hr", "table", "caption", "thead", "tbody", "tfoot", "tr", "th", "td", "colgroup", "col", "a"]
    private let common: Set<String> = ["id", "class", "title", "lang", "dir", "role", "aria-label", "aria-hidden"]
    private let voidTags: Set<String> = ["br", "hr", "col"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        elements += 1
        if name == "navcenter", depth == 1 { return }
        guard depth <= 64, elements <= 20_000, tags.contains(name), namespaceURI == nil else { reject(parser, "HTML element <\(name.prefix(32))>"); return }
        do {
            for (key, value) in attributes {
                if key == "style" { try InertDocumentRenderer.validateCSS(value) }
                else if key == "href", name == "a" {
                    guard !value.unicodeScalars.contains(where: { $0.value <= 32 }), !value.contains("\\") else { throw InertDocumentRenderer.unsupported("link URLs containing controls or escapes") }
                    let scheme = URLComponents(string: value)?.scheme?.lowercased()
                    guard value.hasPrefix("#") || ["https", "http", "mailto", "tel"].contains(scheme ?? "") else { throw InertDocumentRenderer.unsupported("file, relative or executable links") }
                } else if ["colspan", "rowspan", "span", "start", "value", "width"].contains(key) {
                    guard value.range(of: #"^[0-9]{1,5}%?$"#, options: .regularExpression) != nil else { throw InertDocumentRenderer.unsupported("non-numeric table or list attributes") }
                } else if key == "type", name == "ol" {
                    guard ["1", "a", "A", "i", "I"].contains(value) else { throw InertDocumentRenderer.unsupported("ordered-list type") }
                } else if key == "align", ["td", "th", "col"].contains(name) {
                    guard ["left", "right", "center", "justify"].contains(value) else { throw InertDocumentRenderer.unsupported("table alignment") }
                } else if !common.contains(key) { throw InertDocumentRenderer.unsupported("HTML attribute \(key.prefix(32))") }
            }
            // Normalize an inert full-document wrapper from older converters.
            let tag = name == "html" ? "div" : name
            output += "<" + tag
            for key in attributes.keys.sorted() { output += " \(key)=\"\(InertDocumentRenderer.escaped(attributes[key]!))\"" }
            output += ">"
        } catch { failure = error; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if name == "navcenter", depth == 1 { return }
        if !voidTags.contains(name) { output += "</\(name == "html" ? "div" : name)>" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { output += InertDocumentRenderer.escaped(string) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { output += InertDocumentRenderer.escaped(whitespaceString) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser, "CDATA") }
    func parser(_ parser: XMLParser, foundComment comment: String) { reject(parser, "HTML comments") }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser, "processing instructions") }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser, "external entities"); return nil }
    private func reject(_ parser: XMLParser, _ feature: String) { failure = InertDocumentRenderer.unsupported(feature); parser.abortParsing() }
}

public struct ArtifactExportBatchError: Error, LocalizedError {
    public let completed: [ExportedDocument]
    public let failedInput: String
    public let reason: String
    public var errorDescription: String? {
        "Export failed for \(failedInput). \(completed.count) earlier document(s) were exported successfully. \(reason)"
    }
}
