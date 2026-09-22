import XCTest
@testable import NavCenterCore

final class ATSActionReadinessTests: XCTestCase {
    private var root: URL!
    private var package: URL!
    private let packageName = "2099-01-01_Fixture_Engineer"
    private let report = Data("{\"scores\":{\"overall\":82},\"warnings\":[]}".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-ats-action-" + UUID().uuidString).resolvingSymlinksInPath()
        package = root.appendingPathComponent("applications/" + packageName)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        try Data("# Fixture\nRequires Python and Terraform.".utf8).write(to: package.appendingPathComponent("posting.md"))
        try Data("# Fixture Candidate\nfixture@example.invalid\nSummary\nPython engineer.\nSkills\nPython\nExperience\n- Built Python tools.".utf8).write(to: resume)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private var resume: URL { package.appendingPathComponent("Resume_" + packageName + ".md") }
    private var output: URL { package.appendingPathComponent("artifacts/ats-report.json") }

    private func stagedOutput(_ args: [String], _ cwd: URL) -> URL { cwd.appendingPathComponent(args[3]) }

    func testConfirmationDoesNotRunCommand() throws {
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: false) { _, _, _, _ in
            XCTFail("Unconfirmed ATS command ran")
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "blocked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testInvalidAndFailedOutputPreservePreviousReport() throws {
        for status in [Int32(0), 1] {
            try report.write(to: output)
            let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
                try Data("{partial".utf8).write(to: self.stagedOutput(args, cwd))
                return ProcessResult(status: status, stdout: "", stderr: "fixture error")
            }
            XCTAssertEqual(result.status, "failed")
            XCTAssertEqual(try Data(contentsOf: output), report)
        }
    }

    func testConcurrentReportUpdateIsPreserved() throws {
        try report.write(to: output)
        let newer = Data("{\"scores\":{\"overall\":99},\"warnings\":[]}".utf8)
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try self.report.write(to: self.stagedOutput(args, cwd))
            try newer.write(to: self.output, options: .atomic)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(try Data(contentsOf: output), newer)
    }

    func testScanUsesPrivateInputsAndExplicitWorkspaceRoot() throws {
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, env in
            XCTAssertNotEqual(cwd.resolvingSymlinksInPath(), self.root)
            XCTAssertEqual(env["ATSIM_JOB_HUNT_ROOT"], cwd.path)
            let stagedPackage = cwd.appendingPathComponent(args[1])
            XCTAssertEqual(try Data(contentsOf: stagedPackage.appendingPathComponent(self.resume.lastPathComponent)), try Data(contentsOf: self.resume))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("tracking").path))
            try self.report.write(to: self.stagedOutput(args, cwd))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "succeeded", result.message)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual((saved["scores"] as? [String: Int])?["overall"], 82)
        XCTAssertEqual((saved["input"] as? [String: Any])?["text_source"] as? String, resume.path)
    }

    func testInvalidScoreSchemasPreservePreviousReport() throws {
        for invalid in ["{}", "{\"score\":92}", "{\"scores\":{\"overall\":true},\"warnings\":[]}", "{\"scores\":{\"overall\":101},\"warnings\":[]}", "{\"scores\":{\"overall\":80},\"warnings\":[42]}"] {
            try report.write(to: output)
            let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
                try Data(invalid.utf8).write(to: self.stagedOutput(args, cwd))
                return ProcessResult(status: 0, stdout: "", stderr: "")
            }
            XCTAssertEqual(result.status, "failed", invalid)
            XCTAssertEqual(try Data(contentsOf: output), report)
        }
    }

    func testReportExpansionPreservesPreviousReportAndAllowsRetry() throws {
        try report.write(to: output)
        let prefix = "{\"scores\":{\"overall\":82},\"warnings\":[],\"padding\":\""
        let suffix = "\"}"
        let boundary = Data((prefix + String(repeating: "x", count: 4 * 1024 * 1024 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        XCTAssertEqual(boundary.count, 4 * 1024 * 1024)
        let runner = PackageActionRunner(repoRoot: root)
        let expanded = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try boundary.write(to: self.stagedOutput(args, cwd))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(expanded.status, "failed")
        XCTAssertEqual(try Data(contentsOf: output).count, report.count)
        XCTAssertTrue(try Data(contentsOf: output) == report)
        let retry = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try self.report.write(to: self.stagedOutput(args, cwd))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(retry.status, "succeeded", retry.message)
    }

    func testExportedTextPreferenceCopiesOnlyUsedInputs() throws {
        let extraction = package.appendingPathComponent("artifacts/Resume_Fixture.docx.txt")
        let text = Data("Summary\nExported Python resume".utf8)
        try text.write(to: extraction)
        try Data("unrelated private fixture".utf8).write(to: package.appendingPathComponent("notes.md"))
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            let staged = cwd.appendingPathComponent(args[1])
            XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("artifacts/" + extraction.lastPathComponent)), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent(self.resume.lastPathComponent).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("notes.md").path))
            try self.report.write(to: self.stagedOutput(args, cwd))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "succeeded", result.message)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual((saved["input"] as? [String: Any])?["text_source"] as? String, extraction.path)
    }

    func testChangedResumePreservesReportAndRemovesStaging() throws {
        try report.write(to: output)
        var staging: URL?
        let changed = Data("# Newer resume\nTerraform engineer".utf8)
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            staging = cwd
            try self.report.write(to: self.stagedOutput(args, cwd))
            try changed.write(to: self.resume)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(try Data(contentsOf: output), report)
        XCTAssertEqual(try Data(contentsOf: resume), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staging).path))
    }

    func testThrowingCommandPreservesReport() throws {
        try report.write(to: output)
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try Data("partial".utf8).write(to: self.stagedOutput(args, cwd))
            throw NavCenterError.commandFailed("synthetic process timeout")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(try Data(contentsOf: output), report)
    }

    func testOversizedAndHardlinkedInputsAreRejectedBeforeCommand() throws {
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: resume)
        let runner = PackageActionRunner(repoRoot: root)
        var calls = 0
        let hook: PackageActionRunner.CommandHook = { _, _, _, _ in
            calls += 1
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true, commandHook: hook).status, "failed")
        try Data("# Synthetic resume".utf8).write(to: resume)
        try FileManager.default.linkItem(at: resume, to: root.appendingPathComponent("linked-resume.md"))
        XCTAssertEqual(try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true, commandHook: hook).status, "failed")
        XCTAssertEqual(calls, 0)
    }

    func testInvalidUTF8InputsPreserveReportWithoutRunningCommand() throws {
        try report.write(to: output)
        var calls = 0
        for source in [resume, package.appendingPathComponent("posting.md")] {
            let original = try Data(contentsOf: source)
            try Data([0xFF, 0xFE, 0x41]).write(to: source)
            let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, _, _, _ in
                calls += 1
                return ProcessResult(status: 0, stdout: "", stderr: "")
            }
            XCTAssertEqual(result.status, "failed")
            XCTAssertTrue(result.message.contains("UTF-8"))
            XCTAssertEqual(try Data(contentsOf: output), report)
            try original.write(to: source)
        }
        XCTAssertEqual(calls, 0)
    }

    func testStagedOutputAliasCannotReplaceReport() throws {
        try report.write(to: output)
        let outside = root.appendingPathComponent("outside-report.json")
        try report.write(to: outside)
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try FileManager.default.createSymbolicLink(at: self.stagedOutput(args, cwd), withDestinationURL: outside)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(try Data(contentsOf: output), report)
        XCTAssertEqual(try Data(contentsOf: outside), report)
    }

    func testOutputAliasIsRejectedBeforeCommand() throws {
        let outside = root.appendingPathComponent("outside-report.json")
        try report.write(to: outside)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, _, _, _ in
            XCTFail("Output alias reached ATS command")
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(try Data(contentsOf: outside), report)
    }

    func testInstalledATSRejectsResumeAndPostingAliases() throws {
        guard let binary = ProcessInfo.processInfo.environment["NAV_CENTER_TEST_ATSIM_BIN"] else { throw XCTSkip("Set NAV_CENTER_TEST_ATSIM_BIN for installed ATS integration") }
        for source in [resume, package.appendingPathComponent("posting.md")] {
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            let original = try Data(contentsOf: source)
            let outside = root.appendingPathComponent("outside-" + source.lastPathComponent)
            try original.write(to: outside)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            let result = try PackageActionRunner(repoRoot: root, environment: ["NAV_CENTER_ATSIM_BIN": binary]).run(packageName: packageName, actionKey: "ats-scan", confirmed: true)
            XCTAssertEqual(result.status, "failed", "ATS accepted an input alias: " + source.lastPathComponent)
            try FileManager.default.removeItem(at: source)
            try original.write(to: source)
        }
    }

    func testInstalledATSScanProducesCanonicalReport() throws {
        guard let binary = ProcessInfo.processInfo.environment["NAV_CENTER_TEST_ATSIM_BIN"] else { throw XCTSkip("Set NAV_CENTER_TEST_ATSIM_BIN for installed ATS integration") }
        let result = try PackageActionRunner(repoRoot: root, environment: ["NAV_CENTER_ATSIM_BIN": binary]).run(packageName: packageName, actionKey: "ats-scan", confirmed: true)
        XCTAssertEqual(result.status, "succeeded", result.message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertNotNil((json["scores"] as? [String: Any])?["overall"])
        XCTAssertNotNil(json["warnings"] as? [String])
        XCTAssertEqual((json["input"] as? [String: Any])?["text_source"] as? String, resume.path)
    }

    func testMissingATSToolFailsWithNamedMessageWithoutSpawning() throws {
        let probe = isolatedProbe()
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(packageName: packageName, actionKey: "ats-scan", confirmed: true)
        XCTAssertEqual(result.status, "failed")
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.command, "atsim scan applications/\(packageName) --out applications/\(packageName)/artifacts/ats-report.json")
        XCTAssertEqual(result.message, "ATS scan needs atsim, which was not found on PATH or in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin. Set NAV_CENTER_ATSIM_BIN to its absolute path, or install atsim into an isolated Python environment and expose its launcher on PATH and reopen Nav Center.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testHookExitCode127MapsToNamedToolMessage() throws {
        let probe = isolatedProbe()
        var calls = 0
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { executable, _, _, _ in
            calls += 1
            XCTAssertEqual(executable, "atsim")
            return ProcessResult(status: 127, stdout: "", stderr: "command not found")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.message, "ATS scan needs atsim, which was not found on PATH or in /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin. Set NAV_CENTER_ATSIM_BIN to its absolute path, or install atsim into an isolated Python environment and expose its launcher on PATH and reopen Nav Center.")
        XCTAssertFalse(result.message.contains("exit code"))
    }

    func testHookNonZeroExitOtherThan127KeepsExitCodeMessage() throws {
        let probe = isolatedProbe()
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, _, _, _ in
            ProcessResult(status: 3, stdout: "", stderr: "fixture")
        }
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.message, "ATS scan failed with exit code 3.")
    }

    func testFoundToolExitingOneTwentySevenKeepsExitCodeMessage() throws {
        let script = root.appendingPathComponent("bin/atsim")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stderrMarker = "found-tool-exit-127"
        let body = """
        #!/bin/sh
        echo \(stderrMarker) >&2
        exit 127
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let probe = ToolProbeConfiguration(
            environment: ["PATH": "", "NAV_CENTER_ATSIM_BIN": script.path],
            homeDirectory: root,
            fallbackDirectories: []
        )
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(
            packageName: packageName,
            actionKey: "ats-scan",
            confirmed: true
        )
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.message, "ATS scan failed with exit code 127.")
        XCTAssertTrue(result.stderrTail.contains(stderrMarker))
    }

    func testBuiltInExportRefusesWhenRunnerEnvironmentDiffersFromProbe() throws {
        let marker = root.appendingPathComponent("export-spawned")
        let exporter = root.appendingPathComponent("acme-export")
        let script = "#!/bin/sh\nprintf spawned > '\(marker.path)'\nexit 0\n"
        try Data(script.utf8).write(to: exporter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exporter.path)
        let probe = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: root,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in false }
        )
        let environment = ["PATH": "", "NAV_CENTER_EXPORT_BIN": exporter.path]
        let result = try PackageActionRunner(repoRoot: root, environment: environment, toolProbe: probe).run(
            packageName: packageName,
            actionKey: "refresh-resume",
            confirmed: true
        )
        XCTAssertEqual(result.status, "failed")
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(
            result.message,
            "Resume PDF refresh needs Export tool, but NAV_CENTER_EXPORT_BIN does not point to an executable file. Fix or unset NAV_CENTER_EXPORT_BIN."
        )
        XCTAssertFalse(result.message.contains(exporter.path))
        XCTAssertFalse(result.message.contains("acme-export"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("artifacts/Resume_\(packageName).pdf").path))
    }

    func testInvalidExportOverrideFailsRefreshWithNamedMessage() throws {
        let missing = root.appendingPathComponent("missing-exporter").path
        let probe = isolatedProbe(environment: ["PATH": "", "NAV_CENTER_EXPORT_BIN": missing])
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(packageName: packageName, actionKey: "refresh-resume", confirmed: true)
        XCTAssertEqual(result.status, "failed")
        XCTAssertNil(result.exitCode)
        XCTAssertNotNil(result.command)
        XCTAssertEqual(result.message, "Resume PDF refresh needs Export tool, but NAV_CENTER_EXPORT_BIN does not point to an executable file. Fix or unset NAV_CENTER_EXPORT_BIN.")
        XCTAssertFalse(result.message.contains(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("artifacts/Resume_\(packageName).pdf").path))
    }

    func testResolvedExecutableIsRecordedInActionLog() throws {
        let script = root.appendingPathComponent("bin/atsim")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        out=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--out" ]; then
            out="$arg"
          fi
          prev="$arg"
        done
        printf '%s\\n' '{"scores":{"overall":82},"warnings":[]}' > "$out"
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let probe = ToolProbeConfiguration(
            environment: ["PATH": "", "NAV_CENTER_ATSIM_BIN": script.path],
            homeDirectory: root,
            fallbackDirectories: [],
            isExecutableRegularFile: { $0 == script.path }
        )
        let runner = PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe)
        let result = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true)
        let expected = "\(script.path) scan applications/\(packageName) --out applications/\(packageName)/artifacts/ats-report.json"
        XCTAssertEqual(result.status, "succeeded", result.message)
        XCTAssertEqual(result.command, expected)
        XCTAssertEqual(runner.actionLog(packageName: packageName).first?.command, expected)
        XCTAssertTrue(result.command?.hasPrefix("/") == true)

        let hooked = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(
            packageName: packageName,
            actionKey: "ats-scan",
            confirmed: true
        ) { _, _, _, _ in
            ProcessResult(status: 2, stdout: "", stderr: "")
        }
        XCTAssertEqual(
            hooked.command,
            "atsim scan applications/\(packageName) --out applications/\(packageName)/artifacts/ats-report.json"
        )
    }

    func testExportArtifactsAliasRunsRefreshResumeWithConfirmation() throws {
        let environment = ["PATH": ""]
        let pdf = package.appendingPathComponent("artifacts/Resume_\(packageName).pdf")
        for (index, key) in ["export-artifacts", "export_artifacts"].enumerated() {
            var spawned = false
            let result = try PackageActionRunner(repoRoot: root, environment: environment).run(
                packageName: packageName,
                actionKey: key,
                confirmed: true
            ) { executable, args, cwd, _ in
                spawned = true
                XCTAssertEqual(executable, "native-export")
                XCTAssertEqual(args, ["export", "applications/\(self.packageName)/Resume_\(self.packageName).md"])
                XCTAssertEqual(cwd.standardizedFileURL.path, self.root.standardizedFileURL.path)
                try Data("%PDF-1.7 synthetic export \(index)\n".utf8).write(to: pdf)
                return ProcessResult(status: 0, stdout: "", stderr: "")
            }
            XCTAssertTrue(spawned, key)
            XCTAssertEqual(result.action, "refresh-resume", key)
            XCTAssertEqual(result.label, "Export Resume Artifacts", key)
            XCTAssertEqual(result.status, "succeeded", result.message)
            XCTAssertEqual(result.message, "Resume artifacts exported: HTML, DOCX, PDF, and text extractions.")
        }
    }

    func testExportArtifactsAliasIsBlockedWithoutConfirmation() throws {
        for key in ["export-artifacts", "export_artifacts"] {
            var spawned = false
            let result = try PackageActionRunner(repoRoot: root, environment: ["PATH": ""]).run(
                packageName: packageName,
                actionKey: key,
                confirmed: false
            ) { _, _, _, _ in
                spawned = true
                return ProcessResult(status: 0, stdout: "", stderr: "")
            }
            XCTAssertFalse(spawned, key)
            XCTAssertEqual(result.status, "blocked", key)
            XCTAssertEqual(result.action, "refresh-resume", key)
            XCTAssertEqual(result.label, "Export Resume Artifacts", key)
            XCTAssertNil(result.exitCode)
        }
        XCTAssertThrowsError(try PackageActionRunner(repoRoot: root).run(
            packageName: packageName,
            actionKey: "export",
            confirmed: false
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Package action is not supported"), error.localizedDescription)
        }
    }

    func testConfirmedExportArtifactsRunsBuiltInExporterThroughPreflight() throws {
        let processList = try ProcessRunner.run("/usr/bin/pgrep", ["-f", "nav-center-nonexistent-\(UUID().uuidString)"], cwd: root)
        guard processList.status == 1 else {
            throw XCTSkip("Chrome shutdown verification requires pgrep access to the process list.")
        }
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("templates/resume.css").path))

        let tools = root.appendingPathComponent("export-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let pandoc = tools.appendingPathComponent("pandoc")
        let chrome = tools.appendingPathComponent("chrome")
        let pdftotext = tools.appendingPathComponent("pdftotext")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then exit 0; fi
        output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; output="$1"; fi
          shift
        done
        if [ -z "$output" ]; then printf 'A complete synthetic document extraction for validation.'; exit 0; fi
        case "$output" in
          *.html) printf '<html>A complete synthetic document.</html>' > "$output" ;;
          *.docx) printf 'PK synthetic document package' > "$output" ;;
          *) exit 9 ;;
        esac
        """.write(to: pandoc, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        for value in "$@"; do
          case "$value" in --print-to-pdf=*) output="${value#--print-to-pdf=}" ;; esac
        done
        printf '%%PDF-1.7 synthetic document' > "$output"
        """.write(to: chrome, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nif [ \"$1\" = \"-v\" ]; then exit 0; fi\nprintf 'A complete synthetic PDF extraction for validation.'\n"
            .write(to: pdftotext, atomically: true, encoding: .utf8)
        for file in [pandoc, chrome, pdftotext] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }

        let environment = [
            "PATH": "",
            "PANDOC_BIN": pandoc.path,
            "CHROME_BIN": chrome.path,
            "PDFTOTEXT_BIN": pdftotext.path,
            "NAV_CENTER_SKIP_VAULT_SYNC": "1"
        ]
        let probe = ToolProbeConfiguration(environment: environment, homeDirectory: root, fallbackDirectories: [])
        let result = try PackageActionRunner(repoRoot: root, environment: environment, toolProbe: probe).run(
            packageName: packageName,
            actionKey: "export-artifacts",
            confirmed: true
        )
        XCTAssertEqual(result.status, "succeeded", result.message)
        XCTAssertEqual(result.message, "Resume artifacts exported: HTML, DOCX, PDF, and text extractions.")
        let artifacts = package.appendingPathComponent("artifacts")
        let base = "Resume_\(packageName)"
        for suffix in ["html", "docx", "pdf", "docx.txt", "pdf.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("\(base).\(suffix)").path), suffix)
        }
    }

    func testExternalExporterSuccessOnlyClaimsRefreshedPDF() throws {
        let executable = root.appendingPathComponent("external-exporter")
        let pdf = package.appendingPathComponent("artifacts/Resume_\(packageName).pdf")
        let result = try PackageActionRunner(repoRoot: root, environment: ["NAV_CENTER_EXPORT_BIN": executable.path]).run(
            packageName: packageName,
            actionKey: "export-artifacts",
            confirmed: true
        ) { command, _, _, _ in
            XCTAssertEqual(command, executable.path)
            try Data("%PDF-1.7 synthetic external export\n".utf8).write(to: pdf)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(result.status, "succeeded", result.message)
        XCTAssertEqual(result.message, "Resume PDF refreshed by the exporter set in NAV_CENTER_EXPORT_BIN.")
    }

    func testBuiltInExportRefusesBeforeCreatingArtifactsWhenPandocMissing() throws {
        let artifacts = package.appendingPathComponent("artifacts")
        try FileManager.default.removeItem(at: artifacts)
        let probe = ToolProbeConfiguration(environment: ["PATH": ""], homeDirectory: root, fallbackDirectories: [])
        let result = try PackageActionRunner(repoRoot: root, environment: probe.environment, toolProbe: probe).run(
            packageName: packageName,
            actionKey: "refresh-resume",
            confirmed: true
        )
        XCTAssertEqual(result.status, "failed")
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.message.hasPrefix("Document export needs Pandoc"), result.message)
        XCTAssertTrue(result.message.contains("Pandoc"), result.message)
        XCTAssertTrue(result.message.contains("PANDOC_BIN"), result.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.path))
    }

    private func isolatedProbe(environment: [String: String] = ["PATH": ""]) -> ToolProbeConfiguration {
        ToolProbeConfiguration(environment: environment, homeDirectory: root, fallbackDirectories: [], isExecutableRegularFile: { _ in false })
    }
}
