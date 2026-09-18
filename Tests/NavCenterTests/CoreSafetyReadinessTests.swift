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
        try Data("Authorization: Bearer SYNTHETIC_TOKEN_NOT_REAL\nemail=synthetic@example.invalid".utf8).write(to: root.appendingPathComponent("logs/example.log"))
        let report = FeedbackDiagnostics(workspaceRoot: root).report(redact: true)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertEqual(report.workspace.path, "<workspace>")
        XCTAssertTrue(report.recentLogs.isEmpty)
        XCTAssertFalse(json.contains("SYNTHETIC_TOKEN"))
        XCTAssertFalse(json.contains("synthetic@example"))
        XCTAssertFalse(json.contains(root.lastPathComponent))
    }
}
