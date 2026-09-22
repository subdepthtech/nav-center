import XCTest
@testable import NavCenterCore

final class ExportToolReadinessTests: XCTestCase {
    func testInstalledExportChainProducesCompleteArtifactSet() throws {
        executionTimeAllowance = 120
        guard ProcessInfo.processInfo.environment["NAV_CENTER_TEST_REAL_EXPORT"] == "1" else {
            throw XCTSkip("Set NAV_CENTER_TEST_REAL_EXPORT=1 for the installed export-chain integration check.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NAV_CENTER_VAULT_DIR")
        environment["NAV_CENTER_SKIP_VAULT_SYNC"] = "1"
        let configuration = ToolProbeConfiguration(environment: environment)
        var missing: [String] = []
        for tool in [ExternalTool.pandoc, .pdftotext, .chrome] {
            let status = ToolProbe.resolve(tool, configuration: configuration)
            if status.state != .found {
                missing.append("\(tool.displayName) (\(status.state.rawValue))")
            }
        }
        if !missing.isEmpty {
            XCTFail("NAV_CENTER_TEST_REAL_EXPORT=1 but required export tools were not found: \(missing.joined(separator: ", ")).")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nav-center-export-readiness-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try WorkspaceManager(workspaceRoot: root).initialize()

        let packageName = "2026-01-01_Synthetic_Engineer"
        let packageURL = root.appendingPathComponent("applications/\(packageName)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let source = """
        # Synthetic Engineer

        This resume is synthetic fixture text for the export chain check.

        ## Experience

        - Built a synthetic document pipeline.
        - Verified HTML, DOCX, PDF, and text extraction output.
        """
        try Data(source.utf8).write(to: packageURL.appendingPathComponent("Resume_\(packageName).md"))

        _ = try ArtifactExporter(repoRoot: root, environment: environment, toolProbe: configuration)
            .export(markdownPaths: ["applications/\(packageName)/Resume_\(packageName).md"])

        let artifacts = packageURL.appendingPathComponent("artifacts")
        let html = artifacts.appendingPathComponent("Resume_\(packageName).html")
        let docx = artifacts.appendingPathComponent("Resume_\(packageName).docx")
        let pdf = artifacts.appendingPathComponent("Resume_\(packageName).pdf")
        let docxText = URL(fileURLWithPath: docx.path + ".txt")
        let pdfText = URL(fileURLWithPath: pdf.path + ".txt")
        for file in [html, docx, pdf, docxText, pdfText] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertTrue(try Data(contentsOf: pdf).starts(with: Data("%PDF-".utf8)))
        XCTAssertFalse(try String(contentsOf: docxText, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(try String(contentsOf: pdfText, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
