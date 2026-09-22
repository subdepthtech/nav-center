import Foundation
import Darwin
import XCTest
@testable import NavCenterCore

final class CoreSafetyReadinessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-safety-\(UUID().uuidString)")
        try PathSafety.createDirectory(root, inside: root, label: "fixture")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAnchoredWritesRejectRootAncestorAndLeafAliasesWithoutOutsideChanges() throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("outside")
        let workspace = root.appendingPathComponent("workspace")
        try PathSafety.createDirectory(outside, inside: root, label: "outside")
        try PathSafety.createDirectory(workspace, inside: root, label: "workspace")
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("tmp"), withDestinationURL: outside)
        XCTAssertThrowsError(try PathSafety.atomicWrite(Data("bad".utf8), to: workspace.appendingPathComponent("tmp/new/child.txt"), inside: workspace, label: "negative"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        let linked = root.appendingPathComponent("linked-workspace")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertThrowsError(try WorkspaceManager(workspaceRoot: linked).initialize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("applications").path))
        let alias = workspace.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: sentinel, to: alias)
        XCTAssertThrowsError(try PathSafety.atomicWrite(Data("bad".utf8), to: alias, inside: workspace, label: "negative"))
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        let normal = workspace.appendingPathComponent("normal/file.txt")
        try PathSafety.atomicWrite(Data("valid".utf8), to: normal, inside: workspace, label: "positive")
        XCTAssertEqual(try PathSafety.readData(normal, inside: workspace, label: "positive"), Data("valid".utf8))
    }

    func testPrivateTemporaryAliasSupportsExistingAndNewTargets() throws {
        let root = URL(fileURLWithPath: "/private/tmp/navcenter-alias-\(UUID().uuidString)/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let target = root.appendingPathComponent("documents/new.txt")
        try PathSafety.atomicWrite(Data("valid".utf8), to: target, inside: root, label: "alias control")
        XCTAssertEqual(try PathSafety.readData(target, inside: root, label: "alias control"), Data("valid".utf8))
    }

    func testDanglingLinkAndSpecialFileAreRejected() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try PathSafety.assertWritablePath(link, inside: root, label: "link"))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try PathSafety.readData(fifo, inside: root, label: "fifo"))
    }

    func testLargeStdoutAndStderrDrainWithoutDeadlock() throws {
        let result = try ProcessRunner.run("/usr/bin/python3", ["-c", "import sys;sys.stdout.write('o'*1048576);sys.stderr.write('e'*1048576)"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 1_048_576)
        XCTAssertEqual(result.stderr.count, 1_048_576)
        let small = try ProcessRunner.run("/usr/bin/printf", ["valid"])
        XCTAssertEqual(small.stdout, "valid")
    }

    func testProcessTimeoutCancellationAndOutputLimitAreExplicit() throws {
        for kind in ["timeout", "cancel", "limit"] {
            let start = Date()
            XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/python3", ["-c", kind == "limit" ? "print('x'*100000)" : "import time;time.sleep(30)"], timeout: 0.25, maximumOutputBytes: 4096, isCancelled: { kind == "cancel" })) { error in
                XCTAssertTrue(error.localizedDescription.lowercased().contains(kind == "limit" ? "limit" : kind == "cancel" ? "cancel" : "timed out"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testProcessTimeoutKillsDescendantHoldingOutputPipes() throws {
        let root = try fixture()
        let pidFile = root.appendingPathComponent("pid")
        let script = "import subprocess,sys; p=subprocess.Popen(['/bin/sleep','30']);open(sys.argv[1],'w').write(str(p.pid))"
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/python3", ["-c", script, pidFile.path], timeout: 0.3))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        // A killed orphan may briefly remain as a zombie; it must never still execute.
        let result = try ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "stat="])
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.stdout.contains("Z"))
    }

    private func processScript(_ body: String, in root: URL) throws -> URL {
        let script = root.appendingPathComponent("process.sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
        return script
    }

    // Observe a zombie without consuming it. This asserts the runner still owns the PID
    // when it evaluates cancellation/limits, including the iteration that observes exit.
    private func exitedProcess(in pidFile: URL, timeout: TimeInterval = 2) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && info.si_pid == pid { return pid }
                if result < 0 && errno != EINTR {
                    XCTFail("Leader was reaped before the final cancellation/signalling decision: \(errno)")
                    return nil
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("Synthetic leader did not exit within the fixture deadline")
        return nil
    }

    private func assertProcessGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Synthetic process \(pid) survived cleanup", file: file, line: line)
    }

    func testExitedProcessOutputLimitRetainsOwnershipUntilCleanup() throws {
        let root = try fixture()
        let pidFile = root.appendingPathComponent("leader.pid")
        let script = try processScript("""
        echo $$ > "$1"
        printf '%s' 'synthetic output exceeding the small capture limit'
        exit 0
        """, in: root)
        var observedPID: pid_t?
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", [script.path, pidFile.path], timeout: 4,
                                                   maximumOutputBytes: 8, isCancelled: {
            observedPID = self.exitedProcess(in: pidFile)
            return false
        })) { error in
            XCTAssertEqual(error as? NavCenterError, .commandFailed("Process output exceeded its limit."))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pid = try XCTUnwrap(observedPID)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        assertProcessGone(pid)
    }

    func testExitedLeaderIsObservedThenSignalledBeforeItIsReaped() throws {
        var observedPID: pid_t?
        let result = try ProcessRunner.runObservingSignals("/bin/sh", ["-c", "exit 0"], timeout: 2) { pid in
            var info = siginfo_t()
            XCTAssertEqual(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT), 0)
            XCTAssertEqual(info.si_pid, pid, "The leader must remain owned through the final group-signal decision")
            observedPID = pid
        }

        XCTAssertEqual(result.status, 0)
        let pid = try XCTUnwrap(observedPID)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testCleanupDeadlineTransfersOnlyOwnedChildToDeferredReaper() throws {
        var transferred: [pid_t] = []
        XCTAssertFalse(ProcessRunner.transferReapingAfterCleanupDeadline(41, ownsChild: false) { transferred.append($0) })
        XCTAssertTrue(transferred.isEmpty)
        XCTAssertTrue(ProcessRunner.transferReapingAfterCleanupDeadline(42, ownsChild: true) { transferred.append($0) })
        XCTAssertEqual(transferred, [42])

        var child: pid_t = 0
        let arguments = [strdup("/bin/sleep"), strdup("0.1"), nil]
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        let spawnStatus = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { envp in
                posix_spawn(&child, "/bin/sleep", nil, nil, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard spawnStatus == 0 else { return XCTFail("Could not spawn deferred-reaper fixture: \(spawnStatus)") }
        var wasReaped = false
        defer {
            if !wasReaped {
                _ = kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }

        XCTAssertTrue(ProcessRunner.transferReapingAfterCleanupDeadline(child, ownsChild: true))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
            if result < 0 && errno == ECHILD {
                wasReaped = true
                break
            }
            XCTAssertTrue(result == 0 || errno == EINTR)
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(wasReaped, "Deferred cleanup did not reap the transferred child")
    }

    func testCancellationAfterLeaderExitPreservesRendererError() throws {
        let root = try fixture()
        let pidFile = root.appendingPathComponent("leader.pid")
        let script = try processScript("echo $$ > \"$1\"\nexit 0\n", in: root)
        var observedPID: pid_t?
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", [script.path, pidFile.path], timeout: 4, isCancelled: {
            observedPID = self.exitedProcess(in: pidFile)
            return true
        })) { error in
            XCTAssertEqual(error as? NavCenterError, .commandFailed("Process cancelled."))
        }
        assertProcessGone(try XCTUnwrap(observedPID))
    }

    func testExitedLeaderDescendantIsGoneAfterTimeoutAndCancellation() throws {
        for cancel in [false, true] {
            let root = try fixture()
            let leaderFile = root.appendingPathComponent("leader.pid")
            let descendantFile = root.appendingPathComponent("descendant.pid")
            let script = try processScript("""
            if [ "$1" = worker ]; then
                trap '' TERM
                echo $$ > "$2"
                exec /bin/sleep 30
            fi
            echo $$ > "$2"
            /bin/sh "$0" worker "$1" &
            while [ ! -s "$1" ]; do /bin/sleep 0.01; done
            exit 0
            """, in: root)
            var observedPID: pid_t?
            let started = Date()
            XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", [script.path, descendantFile.path, leaderFile.path],
                                                       timeout: cancel ? 4 : 0.5, isCancelled: {
                observedPID = self.exitedProcess(in: leaderFile)
                return cancel
            })) { error in
                XCTAssertEqual(error as? NavCenterError, .commandFailed(cancel ? "Process cancelled." : "Process timed out."))
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            XCTAssertNotNil(observedPID)
            let descendant = try XCTUnwrap(pid_t(String(contentsOf: descendantFile).trimmingCharacters(in: .whitespacesAndNewlines)))
            assertProcessGone(descendant)
        }
    }

    func testShellSuccessFullyDrainsBothStreamsAndDecodesExitStatus() throws {
        let root = try fixture()
        let script = try processScript("""
        i=0
        while [ "$i" -lt 4096 ]; do
            printf 'stdout café\\n'
            printf 'stderr résumé\\n' >&2
            i=$((i + 1))
        done
        exit "$1"
        """, in: root)
        for status in [0, 23] {
            let result = try ProcessRunner.run("/bin/sh", [script.path, String(status)], timeout: 5)
            XCTAssertEqual(result.status, Int32(status))
            XCTAssertEqual(result.stdout, String(repeating: "stdout café\n", count: 4096))
            XCTAssertEqual(result.stderr, String(repeating: "stderr résumé\n", count: 4096))
        }
        let signalled = try processScript("kill -KILL $$\n", in: root)
        XCTAssertEqual(try ProcessRunner.run("/bin/sh", [signalled.path], timeout: 2).status, 128 + SIGKILL)
    }

    func testTimeoutEscalatesWhenShellIgnoresSIGTERM() throws {
        let root = try fixture()
        let pidFile = root.appendingPathComponent("leader.pid")
        let script = try processScript("""
        trap '' TERM
        echo $$ > "$1"
        exec /bin/sleep 30
        """, in: root)
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", [script.path, pidFile.path], timeout: 0.25)) { error in
            XCTAssertEqual(error as? NavCenterError, .commandFailed("Process timed out."))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.30)
        XCTAssertLessThan(elapsed, 2)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        assertProcessGone(pid)
    }

    func testFrontmatterEscapesAndCRLFRoundTrip() throws {
        let original = "ACME\\new \"café\"\nline\tend\r"
        let document = "---\r\ncompany: \(Markdown.yamlString(original))\r\n---\r\nBody"
        XCTAssertEqual(Markdown.parseFrontmatter(document).metadata["company"], original)
        XCTAssertEqual(Markdown.parseFrontmatter(document).body, "Body")
        XCTAssertEqual(Markdown.parseFrontmatter("---\ncompany: 'O''Brien'\n---\nBody").metadata["company"], "O'Brien")
        XCTAssertNil(TextUtil.calendarDay("2026-99-99"))
        XCTAssertNil(TextUtil.calendarDay("2025-02-29"))
        XCTAssertNotNil(TextUtil.calendarDay("2024-02-29"))
    }

    func testSafeYAMLRejectsObjectsAliasesMultipleDocumentsAndScalar() throws {
        let root = try fixture()
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let store = MasterResumeStore(repoRoot: root)
        let original = try store.load().content
        let invalid = ["--- !ruby/object:Object\ntable: {}\n", "profile: &p {}\ncopy: *p\n", "profile: {}\n---\nprofile: {}\n", "hello\n", "profile: [x]\n", "x: " + String(repeating: "[", count: 50) + "0" + String(repeating: "]", count: 50)]
        for content in invalid {
            XCTAssertThrowsError(try store.save(content: content))
            XCTAssertEqual(try store.load().content, original)
        }
        let valid = "profile:\n  name: Synthetic Candidate\nexperience: []\nstarted: 2026-09-04\n"
        let result = try store.save(content: valid, expectedContent: original)
        XCTAssertEqual(try String(contentsOf: result.backupURL), original)
        XCTAssertEqual(try store.load().content, valid)
        XCTAssertThrowsError(try store.save(content: "profile: {}", expectedContent: original))
    }

    func testRedactedDiagnosticsNeverIncludesRawLogsOrOverridePath() throws {
        let root = try fixture()
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let home = root.appendingPathComponent("Users/synthetic", isDirectory: true).standardizedFileURL
        let override = home.appendingPathComponent("bin/atsim")
        try FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: override)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: override.path)
        try Data("Authorization: Bearer SYNTHETIC_TOKEN_NOT_REAL\nemail=synthetic@example.invalid\npath=\(home.path)/resume.pdf".utf8).write(to: root.appendingPathComponent("logs/example.log"))
        let probe = ToolProbeConfiguration(
            environment: ["PATH": "", "NAV_CENTER_ATSIM_BIN": override.path],
            homeDirectory: home,
            fallbackDirectories: []
        )
        let report = FeedbackDiagnostics(workspaceRoot: root, homeDirectory: home, toolProbe: probe).report(redact: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        let toolsJSON = String(decoding: try encoder.encode(report.tools), as: UTF8.self)
        XCTAssertEqual(report.workspace.path, "<workspace>")
        XCTAssertTrue(report.recentLogs.isEmpty)
        XCTAssertFalse(json.contains("SYNTHETIC_TOKEN"))
        XCTAssertFalse(json.contains("synthetic@example"))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains(home.path))
        XCTAssertFalse(toolsJSON.contains("/Users/"))
        XCTAssertFalse(toolsJSON.contains(override.path))
        let atsim = try XCTUnwrap(report.tools.tools.first { $0.tool == .atsim })
        XCTAssertEqual(atsim.state, .found)
        XCTAssertNil(atsim.resolvedPath)
        XCTAssertEqual(atsim.summary, "Found via NAV_CENTER_ATSIM_BIN (path hidden in redacted output)")
        XCTAssertFalse(json.contains(root.lastPathComponent))
    }

    func testOversizedPostingIsExcludedWithLimitMessageAndOtherPackagesStillScan() throws {
        let root = try fixture()
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let healthyName = "2026-01-01_Healthy_Package"
        let oversizedName = "2026-01-02_Oversized_Posting"
        let healthy = root.appendingPathComponent("applications/\(healthyName)")
        let oversized = root.appendingPathComponent("applications/\(oversizedName)")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data("# Synthetic posting\n".utf8).write(to: healthy.appendingPathComponent("posting.md"))
        try Data(count: 1_048_577).write(to: oversized.appendingPathComponent("posting.md"))

        let result = try PackageInspector(repoRoot: root).scanWithWarnings()

        XCTAssertEqual(result.packages.map(\.name), [healthyName])
        XCTAssertTrue(result.warnings.contains { $0.contains("was excluded") && $0.contains("1048576") }, result.warnings.joined(separator: "\n"))
    }

    func testInvalidUTF8PostingIsExcludedWithEncodingMessage() throws {
        let root = try fixture()
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let name = "2026-01-03_Invalid_Posting"
        let package = root.appendingPathComponent("applications/\(name)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: package.appendingPathComponent("posting.md"))

        let result = try PackageInspector(repoRoot: root).scanWithWarnings()

        XCTAssertFalse(result.packages.contains { $0.name == name })
        XCTAssertTrue(result.warnings.contains { $0.contains("is not valid UTF-8") }, result.warnings.joined(separator: "\n"))
    }

    func testOversizedInterviewSourcesAreRejectedBeforeKitIsWritten() throws {
        let root = try fixture()
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let name = "2026-01-04_Interview_Package"
        let package = root.appendingPathComponent("applications/\(name)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("---\ncompany: Synthetic\nrole: Engineer\n---\nResponsibilities and requirements.\n".utf8).write(to: package.appendingPathComponent("posting.md"))
        try Data(count: 1_048_577).write(to: package.appendingPathComponent("interview-prep.md"))

        XCTAssertThrowsError(try RealtimeInterviewKitGenerator(repoRoot: root).create(applicationPath: "applications/\(name)", dryRun: false, overwrite: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("1048576"), error.localizedDescription)
        }
        for file in ["interview-realtime-session.json", "interview-transcript.md", "interview-review-prompt.md"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent(file).path), file)
        }
    }
}
