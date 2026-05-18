import XCTest
@testable import NavCenterCore

final class WorkspaceFeatureTests: XCTestCase {
    func testDefaultWorkspaceRootUsesApplicationSupportNavCenterWorkspace() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let root = WorkspaceManager.defaultWorkspaceRoot(homeDirectory: home)

        XCTAssertEqual(root.path, "/Users/example/Library/Application Support/Nav Center/Workspace")
    }

    func testEnvironmentOverrideWinsWithoutPackageSwiftRequirement() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let override = temp.appendingPathComponent("Custom Workspace", isDirectory: true)

        let root = WorkspaceManager.resolveWorkspaceRoot(
            environment: ["NAV_CENTER_WORKSPACE_ROOT": override.path],
            homeDirectory: temp,
            currentDirectory: temp.appendingPathComponent("not-a-repo", isDirectory: true)
        )

        XCTAssertEqual(root.standardizedFileURL.path, override.standardizedFileURL.path)
    }

    func testInitializesWorkspaceLayoutAndSeedMasterResume() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workspace = temp.appendingPathComponent("Workspace", isDirectory: true)

        let result = try WorkspaceManager(workspaceRoot: workspace).initialize()

        XCTAssertEqual(result.workspaceRoot.standardizedFileURL.path, workspace.standardizedFileURL.path)
        for relativePath in [
            "applications",
            "master-resumes",
            "tracking",
            "imports/originals",
            "imports/markdown",
            "backups",
            "logs",
            "feedback"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: workspace.appendingPathComponent(relativePath, isDirectory: true).path),
                "Missing \(relativePath)"
            )
        }

        let masterResume = workspace.appendingPathComponent("master-resumes/master_primary.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: masterResume.path))
        XCTAssertTrue(try String(contentsOf: masterResume).contains("Example Candidate"))
    }

    func testDocumentImporterCopiesOriginalAndCreatesMarkdownCopy() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workspace = temp.appendingPathComponent("Workspace", isDirectory: true)
        try WorkspaceManager(workspaceRoot: workspace).initialize()
        let source = temp.appendingPathComponent("Austin Resume.txt")
        try "Built secure local-first tooling.\nLed security reviews.".write(to: source, atomically: true, encoding: .utf8)

        let result = try DocumentImporter(workspaceRoot: workspace).importDocuments([source]).first

        XCTAssertEqual(result?.originalRelativePath, "imports/originals/Austin_Resume.txt")
        XCTAssertEqual(result?.markdownRelativePath, "imports/markdown/Austin_Resume.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("imports/originals/Austin_Resume.txt").path))
        let markdown = try String(contentsOf: workspace.appendingPathComponent("imports/markdown/Austin_Resume.md"))
        XCTAssertTrue(markdown.contains("source_kind: \"txt\""))
        XCTAssertTrue(markdown.contains("Built secure local-first tooling."))
    }

    func testFeedbackDiagnosticsRedactsHomePathAndReportsWorkspaceHealth() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("Users/tucker", isDirectory: true)
        let workspace = home.appendingPathComponent("Library/Application Support/Nav Center/Workspace", isDirectory: true)
        try WorkspaceManager(workspaceRoot: workspace).initialize()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)
        try "Opened /Users/tucker/private/resume.pdf".write(
            to: workspace.appendingPathComponent("logs/nav-center.log"),
            atomically: true,
            encoding: .utf8
        )

        let report = FeedbackDiagnostics(
            workspaceRoot: workspace,
            homeDirectory: home,
            appVersion: "0.1.0-beta"
        ).report(redact: true)
        let json = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? ""

        XCTAssertEqual(report.appVersion, "0.1.0-beta")
        XCTAssertTrue(report.workspace.exists)
        XCTAssertTrue(report.workspace.requiredDirectoriesMissing.isEmpty)
        XCTAssertFalse(json.contains("/Users/tucker"))
        XCTAssertTrue(json.contains("<home>"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nav-center-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
