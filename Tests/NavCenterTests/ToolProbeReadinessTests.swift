import XCTest
@testable import NavCenterCore

final class ToolProbeReadinessTests: XCTestCase {
    private let chromeBundle = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)

    func testOverrideAbsolutePathIsFoundWhenExecutableRegularFile() throws {
        let root = try makeRoot()
        let binary = root.appendingPathComponent("bin/atsim")
        try writeExecutable(binary)
        let status = ToolProbe.resolve(.atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": binary.path, "PATH": ""], root: root))
        XCTAssertEqual(status.state, .found)
        XCTAssertEqual(status.source, .environment)
        XCTAssertEqual(status.resolvedPath, binary.path)
        XCTAssertEqual(status.summary, "found at \(binary.path) (environment override)")
        XCTAssertEqual(ToolProbe.executablePath(for: .atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": binary.path, "PATH": ""], root: root)), binary.path)
    }

    func testOverrideMissingOrNonExecutableFileIsOverrideInvalidNotMissing() throws {
        let root = try makeRoot()
        let missing = root.appendingPathComponent("missing-atsim").path
        let missingStatus = ToolProbe.resolve(.atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": missing, "PATH": root.path], root: root))
        XCTAssertEqual(missingStatus.state, .overrideInvalid)
        XCTAssertNotEqual(missingStatus.state, .missing)
        XCTAssertEqual(missingStatus.resolvedPath, missing)
        XCTAssertNil(missingStatus.source)
        XCTAssertNil(ToolProbe.executablePath(for: .atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": missing, "PATH": root.path], root: root)))

        let file = root.appendingPathComponent("atsim-not-executable")
        try Data("not executable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let unexecutable = ToolProbe.resolve(.atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": file.path, "PATH": ""], root: root))
        XCTAssertEqual(unexecutable.state, .overrideInvalid)
        XCTAssertEqual(unexecutable.resolvedPath, file.path)
        XCTAssertEqual(unexecutable.summary, "NAV_CENTER_ATSIM_BIN is not an executable file")
    }

    func testOverrideDirectoryIsNotTreatedAsExecutable() throws {
        let root = try makeRoot()
        let directory = root.appendingPathComponent("atsim-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.path))
        let status = ToolProbe.resolve(.atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": directory.path, "PATH": ""], root: root))
        XCTAssertEqual(status.state, .overrideInvalid)
        XCTAssertNotEqual(status.state, .found)
        XCTAssertNotEqual(status.state, .missing)
        XCTAssertEqual(status.resolvedPath, directory.path)
    }

    func testEmptyOverrideFallsBackToDefaultLookup() throws {
        let root = try makeRoot()
        let directory = root.appendingPathComponent("path-bin", isDirectory: true)
        let binary = directory.appendingPathComponent("atsim")
        try writeExecutable(binary)
        let status = ToolProbe.resolve(.atsim, configuration: isolated(environment: ["NAV_CENTER_ATSIM_BIN": "", "PATH": directory.path], root: root))
        XCTAssertEqual(status.state, .found)
        XCTAssertEqual(status.source, .path)
        XCTAssertEqual(status.resolvedPath, binary.path)
    }

    func testPathDirectoriesAreSearchedBeforeFallbackDirectories() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "/search-a:/search-b", "PANDOC_BIN": ""],
            homeDirectory: home,
            fallbackDirectories: ["/fallback-a", "/fallback-b"],
            isExecutableRegularFile: { path in
                recorder.record(path)
                return path == "/search-b/pandoc"
            }
        )
        let status = ToolProbe.resolve(.pandoc, configuration: configuration)
        XCTAssertEqual(recorder.paths, ["/search-a/pandoc", "/search-b/pandoc"])
        XCTAssertEqual(status.state, .found)
        XCTAssertEqual(status.source, .path)
        XCTAssertEqual(status.resolvedPath, "/search-b/pandoc")
        XCTAssertEqual(status.summary, "found at /search-b/pandoc (PATH)")
    }

    func testFallbackDirectoriesAreSearchedInFixedOrderWhenPathIsEmpty() {
        let fallbacks = ToolProbe.fallbackDirectories(homeDirectory: home)
        XCTAssertEqual(fallbacks, ["/opt/homebrew/bin", "/usr/local/bin", "/Users/synthetic/.local/bin"])
        let recorder = PathRecorder()
        let chosen = fallbacks[2] + "/ruby"
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { path in
                recorder.record(path)
                return path == chosen
            }
        )
        let status = ToolProbe.resolve(.ruby, configuration: configuration)
        XCTAssertEqual(recorder.paths, fallbacks.map { $0 + "/ruby" })
        XCTAssertEqual(status.state, .found)
        XCTAssertEqual(status.source, .fallback)
        XCTAssertEqual(status.resolvedPath, chosen)
        XCTAssertEqual(status.summary, "found at \(chosen) (fallback directory)")
    }

    func testChromeDefaultsToApplicationsBundlePath() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin", "CHROME_BIN": ""],
            homeDirectory: home,
            fallbackDirectories: ["/opt/homebrew/bin"],
            isExecutableRegularFile: { path in
                recorder.record(path)
                return path == self.chromeBundle
            }
        )
        let status = ToolProbe.resolve(.chrome, configuration: configuration)
        XCTAssertEqual(recorder.paths, [chromeBundle])
        XCTAssertEqual(status.state, .found)
        XCTAssertEqual(status.source, .defaultPath)
        XCTAssertEqual(status.resolvedPath, chromeBundle)
        XCTAssertEqual(status.summary, "found at \(chromeBundle) (default path)")
    }

    func testExportToolReportsBuiltInWhenOverrideUnset() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: ["/opt/homebrew/bin"],
            isExecutableRegularFile: { path in
                recorder.record(path)
                return true
            }
        )
        let status = ToolProbe.resolve(.exportTool, configuration: configuration)
        XCTAssertEqual(recorder.paths, [])
        XCTAssertEqual(status.state, .builtIn)
        XCTAssertNil(status.resolvedPath)
        XCTAssertNil(status.source)
        XCTAssertEqual(status.summary, "built-in")
        XCTAssertEqual(status.environmentVariable, "NAV_CENTER_EXPORT_BIN")
        XCTAssertNil(ToolProbe.executablePath(for: .exportTool, configuration: configuration))
    }

    func testCodexResolutionOrderMatchesPreviousBridgeBehaviour() {
        let explicit = PathRecorder()
        let override = ToolProbeConfiguration(
            environment: ["DASHBOARD_CODEX_BIN": "/opt/custom/codex", "PATH": "/should-not-search"],
            homeDirectory: home,
            fallbackDirectories: ToolProbe.fallbackDirectories(homeDirectory: home),
            isExecutableRegularFile: { path in
                explicit.record(path)
                return path == "/opt/custom/codex"
            }
        )
        let overridden = ToolProbe.resolve(.codex, configuration: override)
        XCTAssertEqual(explicit.paths, ["/opt/custom/codex"])
        XCTAssertEqual(overridden.state, .found)
        XCTAssertEqual(overridden.source, .environment)
        XCTAssertEqual(overridden.resolvedPath, "/opt/custom/codex")

        let lookup = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin:/opt/custom/bin", "DASHBOARD_CODEX_BIN": ""],
            homeDirectory: home,
            isExecutableRegularFile: { path in
                lookup.record(path)
                return false
            }
        )
        let missing = ToolProbe.resolve(.codex, configuration: configuration)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(lookup.paths, [
            "/usr/bin/codex",
            "/opt/custom/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Users/synthetic/.local/bin/codex",
        ])
    }

    func testProbeQueriesOnlyExpectedCandidatePathsInOrder() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "/opt/a:/opt/b:", "PANDOC_BIN": ""],
            homeDirectory: home,
            fallbackDirectories: nil,
            isExecutableRegularFile: { path in
                recorder.record(path)
                return false
            }
        )
        let status = ToolProbe.resolve(.pandoc, configuration: configuration)
        XCTAssertEqual(status.state, .missing)
        XCTAssertNil(status.resolvedPath)
        XCTAssertEqual(recorder.paths, [
            "/opt/a/pandoc",
            "/opt/b/pandoc",
            "/opt/homebrew/bin/pandoc",
            "/usr/local/bin/pandoc",
            "/Users/synthetic/.local/bin/pandoc",
        ])
    }

    func testReportContainsEveryToolOnceInDeclarationOrder() {
        let report = ToolProbe.report(configuration: ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in false }
        ))
        XCTAssertEqual(report.tools.map(\.tool), ExternalTool.allCases)
        XCTAssertEqual(report.tools.map(\.id), ExternalTool.allCases.map(\.rawValue))
        XCTAssertEqual(Set(report.tools.map(\.tool)).count, 7)
        XCTAssertEqual(report.tools.map(\.state), [.missing, .builtIn, .missing, .missing, .missing, .missing, .missing])
        XCTAssertEqual(report.missing.map(\.tool), [.atsim, .pandoc, .pdftotext, .chrome, .ruby, .codex])
        XCTAssertEqual(ToolAvailabilityReport.empty.tools, [])
    }

    func testRelativeOverridePathIsOverrideInvalid() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["NAV_CENTER_ATSIM_BIN": "tools/atsim", "PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: ["/opt/homebrew/bin"],
            isExecutableRegularFile: { path in
                recorder.record(path)
                return true
            }
        )
        let status = ToolProbe.resolve(.atsim, configuration: configuration)
        XCTAssertEqual(status.state, .overrideInvalid)
        XCTAssertEqual(status.summary, "NAV_CENTER_ATSIM_BIN must be an absolute path")
        XCTAssertEqual(status.resolvedPath, "tools/atsim")
        XCTAssertNil(status.source)
        XCTAssertEqual(recorder.paths, [])
        XCTAssertNil(ToolProbe.executablePath(for: .atsim, configuration: configuration))
    }

    func testRelativePathEntriesAreSkipped() {
        let recorder = PathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": "bin:tools/atsim:/usr/bin:", "PANDOC_BIN": ""],
            homeDirectory: home,
            fallbackDirectories: ["relative-fallback", "/opt/homebrew/bin"],
            isExecutableRegularFile: { path in
                recorder.record(path)
                return false
            }
        )
        let missing = ToolProbe.resolve(.pandoc, configuration: configuration)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertNil(missing.resolvedPath)
        XCTAssertEqual(recorder.paths, ["/usr/bin/pandoc", "/opt/homebrew/bin/pandoc"])

        let found = ToolProbe.resolve(.ruby, configuration: ToolProbeConfiguration(
            environment: ["PATH": "bin"],
            homeDirectory: home,
            fallbackDirectories: ["relative-fallback", "/usr/bin"],
            isExecutableRegularFile: { $0 == "/usr/bin/ruby" }
        ))
        XCTAssertEqual(found.state, .found)
        XCTAssertEqual(found.source, .fallback)
        XCTAssertEqual(found.resolvedPath, "/usr/bin/ruby")
        XCTAssertTrue(found.resolvedPath?.hasPrefix("/") == true)
    }

    func testReportRedactsHomeDirectoryInResolvedPathsAndSummaries() {
        let path = "/Users/synthetic/bin/pandoc"
        let invalid = "/Users/synthetic/missing-atsim"
        let report = ToolProbe.report(configuration: ToolProbeConfiguration(
            environment: ["PATH": "", "PANDOC_BIN": path, "NAV_CENTER_ATSIM_BIN": invalid],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { $0 == path }
        ))
        let redacted = report.redacted(homeDirectory: home)
        let pandoc = redacted.tools.first { $0.tool == .pandoc }
        let atsim = redacted.tools.first { $0.tool == .atsim }
        XCTAssertEqual(pandoc?.resolvedPath, "<home>/bin/pandoc")
        XCTAssertEqual(pandoc?.summary, "found at <home>/bin/pandoc (environment override)")
        XCTAssertEqual(atsim?.state, .overrideInvalid)
        XCTAssertEqual(atsim?.resolvedPath, "<home>/missing-atsim")
        XCTAssertFalse(redacted.tools.contains { ($0.resolvedPath ?? "").contains("/Users/synthetic") || $0.summary.contains("/Users/synthetic") })
    }

    func testReportRedactsOtherUserHomePathsLikeDiagnostics() throws {
        let other = "/Users/other-person/bin/atsim"
        let redacted = ToolProbe.report(configuration: ToolProbeConfiguration(
            environment: ["PATH": "", "NAV_CENTER_ATSIM_BIN": other],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { $0 == other }
        )).redacted(homeDirectory: home)
        let atsim = try XCTUnwrap(redacted.tools.first { $0.tool == .atsim })
        XCTAssertEqual(atsim.state, .found)
        XCTAssertEqual(atsim.resolvedPath, "<home>/bin/atsim")
        XCTAssertEqual(atsim.summary, "found at <home>/bin/atsim (environment override)")
        XCTAssertEqual(PathRedactor.redact(other, homeDirectory: home), "<home>/bin/atsim")
        XCTAssertEqual(PathRedactor.redact("owner synthetic at /opt/synthetic/tool", homeDirectory: home), "owner <user> at /opt/<user>/tool")
        XCTAssertFalse(atsim.resolvedPath?.contains("/Users/") == true)
        XCTAssertFalse(atsim.summary.contains("other-person"))
        XCTAssertFalse(redacted.tools.contains { ($0.resolvedPath ?? "").contains("/Users/") || $0.summary.contains("/Users/") })
    }

    func testMissingToolMessageNamesToolEnvironmentVariableAndInstallHint() {
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in false }
        )
        let atsim = ToolProbe.resolve(.atsim, configuration: configuration)
        XCTAssertEqual(
            ToolProbe.missingToolMessage(atsim, action: "ATS scan"),
            "ATS scan needs atsim, which was not found on PATH or in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin. Set NAV_CENTER_ATSIM_BIN to its absolute path, or install atsim into an isolated Python environment and expose its launcher on PATH and reopen Nav Center."
        )
        let ruby = ToolProbe.resolve(.ruby, configuration: configuration)
        XCTAssertNil(ruby.environmentVariable)
        XCTAssertEqual(
            ToolProbe.missingToolMessage(ruby, action: "Master resume save"),
            "Master resume save needs Ruby, which was not found on PATH. Reinstall Xcode Command Line Tools or use the Ruby included with macOS at /usr/bin/ruby."
        )
    }

    func testOverrideInvalidMessageNeverContainsThePath() {
        let secret = "/Users/synthetic/not-a-real-binary-\(UUID().uuidString)"
        let status = ToolProbe.resolve(.atsim, configuration: ToolProbeConfiguration(
            environment: ["NAV_CENTER_ATSIM_BIN": secret, "PATH": ""],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in false }
        ))
        XCTAssertEqual(status.state, .overrideInvalid)
        XCTAssertEqual(status.resolvedPath, secret)
        let message = ToolProbe.missingToolMessage(status, action: "ATS scan")
        XCTAssertEqual(message, "ATS scan needs atsim, but NAV_CENTER_ATSIM_BIN does not point to an executable file. Fix or unset NAV_CENTER_ATSIM_BIN.")
        XCTAssertFalse(message.contains(secret))
        XCTAssertFalse(message.contains("not-a-real-binary"))
    }

    private func isolated(environment: [String: String], root: URL) -> ToolProbeConfiguration {
        ToolProbeConfiguration(environment: environment, homeDirectory: root, fallbackDirectories: [])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-tool-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ path: String) {
        lock.lock()
        recorded.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
