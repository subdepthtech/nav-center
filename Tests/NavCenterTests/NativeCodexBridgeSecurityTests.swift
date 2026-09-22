import Foundation
import Darwin
import XCTest
import NavCenterCore
@testable import NavCenterApp

final class NativeCodexBridgeSecurityTests: XCTestCase {
    func testApprovalFailsClosedAndAcceptsOnlyCanonicalStagedMarkdown() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        let params: [String: Any] = [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "item-1"
        ]
        XCTAssertTrue(
            NativeCodexBridge.shouldApproveFileChange(
                params: params,
                expectedThreadID: "thread-1",
                allowEdits: true,
                editRoot: broker.stagingURL,
                paths: ["posting.md"]
            )
        )
        XCTAssertFalse(
            NativeCodexBridge.shouldApproveFileChange(
                params: params,
                expectedThreadID: nil,
                allowEdits: true,
                editRoot: broker.stagingURL,
                paths: ["posting.md"]
            )
        )
        XCTAssertFalse(
            NativeCodexBridge.shouldApproveFileChange(
                params: params,
                expectedThreadID: "thread-1",
                allowEdits: true,
                editRoot: broker.stagingURL,
                paths: nil
            )
        )
        XCTAssertFalse(
            NativeCodexBridge.shouldApproveFileChange(
                params: params,
                expectedThreadID: "thread-1",
                allowEdits: true,
                editRoot: broker.stagingURL,
                paths: []
            )
        )
        XCTAssertFalse(
            NativeCodexBridge.shouldApproveFileChange(
                params: params.merging(["grantRoot": fixture.root.path]) { _, new in new },
                expectedThreadID: "thread-1",
                allowEdits: true,
                editRoot: broker.stagingURL,
                paths: ["posting.md"]
            )
        )
        XCTAssertFalse(CodexPackageEditBroker.approvalPathsAreAllowed(["../posting.md"], inside: broker.stagingURL))
        XCTAssertFalse(CodexPackageEditBroker.approvalPathsAreAllowed([fixture.package.appendingPathComponent("posting.md").path], inside: broker.stagingURL))
        XCTAssertFalse(CodexPackageEditBroker.approvalPathsAreAllowed(["artifact.json"], inside: broker.stagingURL))

        let outside = fixture.root.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let symlink = broker.stagingURL.appendingPathComponent("Resume_escape.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        XCTAssertFalse(CodexPackageEditBroker.approvalPathsAreAllowed(["Resume_escape.md"], inside: broker.stagingURL))
    }

    func testWorkspaceWritePolicyUsesOnlyStagingAndExcludesOtherTemporaryRoots() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        let policy = NativeCodexBridge.workspaceWriteSandboxPolicy(editRoot: broker.stagingURL)
        XCTAssertEqual(policy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(policy["writableRoots"] as? [String], [broker.stagingURL.path])
        XCTAssertEqual(policy["networkAccess"] as? Bool, false)
        XCTAssertEqual(policy["excludeTmpdirEnvVar"] as? Bool, true)
        XCTAssertEqual(policy["excludeSlashTmp"] as? Bool, true)
        XCTAssertNotEqual((policy["writableRoots"] as? [String])?.first, fixture.root.path)
    }

    func testFileChangeLifecycleUsesDocumentedItemStartedAndPatchUpdatedShapes() {
        let changes: [[String: Any]] = [
            ["path": "posting.md", "diff": "@@ posting @@", "kind": "update"]
        ]
        XCTAssertEqual(
            NativeCodexBridge.fileChangeUpdate(
                method: "item/started",
                params: [
                    "item": ["id": "item-1", "type": "fileChange", "status": "inProgress", "changes": changes],
                    "threadId": "thread-1",
                    "turnId": "turn-1"
                ]
            ),
            CodexFileChangeUpdate(itemID: "item-1", paths: ["posting.md"], diff: "@@ posting @@")
        )
        XCTAssertEqual(
            NativeCodexBridge.fileChangeUpdate(
                method: "item/fileChange/patchUpdated",
                params: [
                    "itemId": "item-1",
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "changes": changes
                ]
            ),
            CodexFileChangeUpdate(itemID: "item-1", paths: ["posting.md"], diff: "@@ posting @@")
        )
        XCTAssertTrue(
            NativeCodexBridge.shouldQueueApproval(
                turnID: "turn-1",
                hasActiveTurn: false,
                isActivating: false
            )
        )
        XCTAssertTrue(
            NativeCodexBridge.shouldQueueApproval(
                turnID: "turn-1",
                hasActiveTurn: true,
                isActivating: true
            )
        )
        XCTAssertFalse(
            NativeCodexBridge.shouldQueueApproval(
                turnID: "turn-1",
                hasActiveTurn: true,
                isActivating: false
            )
        )
    }

    func testBrokerAppliesAllowedMarkdownAndLeavesOtherPackageFilesUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        try Data("updated posting".utf8).write(to: broker.stagingURL.appendingPathComponent("posting.md"), options: .atomic)
        try Data("new resume".utf8).write(to: broker.stagingURL.appendingPathComponent("Resume_new.md"), options: .atomic)

        XCTAssertEqual(try broker.applyValidatedChanges(), ["Resume_new.md", "posting.md"])
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("posting.md")), "updated posting")
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("Resume_new.md")), "new resume")
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("artifact.json")), "keep")
    }

    func testBrokerRejectsUnexpectedStagedEntryWithoutChangingPackage() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        try Data("updated posting".utf8).write(to: broker.stagingURL.appendingPathComponent("posting.md"), options: .atomic)
        try Data("bad".utf8).write(to: broker.stagingURL.appendingPathComponent("tracker.json"))

        XCTAssertThrowsError(try broker.applyValidatedChanges())
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("posting.md")), "original posting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent("tracker.json").path))
    }

    func testBrokerRejectsConcurrentPackageChangeWithoutOverwritingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        try Data("staged posting".utf8).write(to: broker.stagingURL.appendingPathComponent("posting.md"), options: .atomic)
        try Data("user changed posting".utf8).write(to: fixture.package.appendingPathComponent("posting.md"), options: .atomic)

        XCTAssertThrowsError(try broker.applyValidatedChanges())
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("posting.md")), "user changed posting")
    }

    func testBrokerRechecksConcurrentPackageChangeAtCommitBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }

        try Data("staged posting".utf8).write(to: broker.stagingURL.appendingPathComponent("posting.md"), options: .atomic)

        XCTAssertThrowsError(
            try broker.applyValidatedChanges {
                try Data("user changed posting".utf8).write(
                    to: fixture.package.appendingPathComponent("posting.md"),
                    options: .atomic
                )
            }
        )
        XCTAssertEqual(try String(contentsOf: fixture.package.appendingPathComponent("posting.md")), "user changed posting")
    }

    func testStagingDirectoryIsPrivateAndCleanupFailureIsReported() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        let posting = broker.stagingURL.appendingPathComponent("posting.md")
        defer {
            _ = chflags(posting.path, 0)
            try? broker.cleanup()
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: broker.stagingURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o700)

        XCTAssertEqual(chflags(posting.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertThrowsError(try broker.cleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: broker.stagingURL.path))
        XCTAssertEqual(chflags(posting.path, 0), 0)
        try broker.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: broker.stagingURL.path))
    }

    func testBrokerRejectsReboundPackageRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let broker = try CodexPackageEditBroker(packageURL: fixture.package, stagingParent: fixture.stagingParent)
        defer { try? broker.cleanup() }
        try Data("staged posting".utf8).write(to: broker.stagingURL.appendingPathComponent("posting.md"), options: .atomic)

        let originalPackage = fixture.root.appendingPathComponent("original-package")
        let replacementPackage = fixture.root.appendingPathComponent("replacement-package")
        try FileManager.default.moveItem(at: fixture.package, to: originalPackage)
        try FileManager.default.createDirectory(at: replacementPackage, withIntermediateDirectories: false)
        try Data("original posting".utf8).write(to: replacementPackage.appendingPathComponent("posting.md"))
        try FileManager.default.createSymbolicLink(at: fixture.package, withDestinationURL: replacementPackage)

        XCTAssertThrowsError(try broker.applyValidatedChanges())
        XCTAssertEqual(try String(contentsOf: replacementPackage.appendingPathComponent("posting.md")), "original posting")
    }

    func testCodexCommandResolutionUsesToolProbeOrder() throws {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/Users/synthetic/.local/bin"]

        let override = ToolProbeConfiguration(
            environment: ["DASHBOARD_CODEX_BIN": "/opt/custom/codex", "PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { $0 == "/opt/custom/codex" }
        )
        XCTAssertEqual(try NativeCodexBridge.resolveCodexCommand(configuration: override), "/opt/custom/codex")

        let pathBeforeFallback = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin:/opt/custom/bin"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { $0 == "/opt/custom/bin/codex" || $0 == "/opt/homebrew/bin/codex" }
        )
        XCTAssertEqual(try NativeCodexBridge.resolveCodexCommand(configuration: pathBeforeFallback), "/opt/custom/bin/codex")

        let searched = CodexCommandPathRecorder()
        let fallbackOnly = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { path in
                searched.record(path)
                return path == "/Users/synthetic/.local/bin/codex"
            }
        )
        XCTAssertEqual(
            try NativeCodexBridge.resolveCodexCommand(configuration: fallbackOnly),
            "/Users/synthetic/.local/bin/codex"
        )
        XCTAssertEqual(searched.paths, fallbacks.map { $0 + "/codex" })

        let invalidOverride = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin", "DASHBOARD_CODEX_BIN": "/missing/codex"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { _ in false }
        )
        try assertCodexRefusesWithoutSpawning(configuration: invalidOverride)

        let relativeOverride = ToolProbeConfiguration(
            environment: ["DASHBOARD_CODEX_BIN": "tools/codex", "PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { _ in true }
        )
        try assertCodexRefusesWithoutSpawning(configuration: relativeOverride, decoyRelativePath: "tools/codex")

        let missing = ToolProbeConfiguration(
            environment: ["PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { _ in false }
        )
        try assertCodexRefusesWithoutSpawning(configuration: missing, decoyRelativePath: "codex")

        let bareNameMissing = ToolProbeConfiguration(
            environment: ["DASHBOARD_CODEX_BIN": "custom-codex", "PATH": "/usr/bin"],
            homeDirectory: home,
            fallbackDirectories: fallbacks,
            isExecutableRegularFile: { _ in false }
        )
        try assertCodexRefusesWithoutSpawning(configuration: bareNameMissing, decoyRelativePath: "custom-codex")
    }

    func testEmptyOrRelativePathEntryIsNeverUsed() throws {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        let searched = CodexCommandPathRecorder()
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": ":.:relbin:/opt/codex-not-present"],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { path in
                searched.record(path)
                return false
            }
        )
        XCTAssertThrowsError(try NativeCodexBridge.resolveCodexCommand(configuration: configuration)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Codex"), message)
            XCTAssertTrue(message.contains("DASHBOARD_CODEX_BIN"), message)
        }
        XCTAssertEqual(searched.paths, ["/opt/codex-not-present/codex"])
        XCTAssertTrue(searched.paths.allSatisfy { $0.hasPrefix("/") })

        let empty = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: home,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in
                XCTFail("An empty PATH produced a candidate")
                return true
            }
        )
        try assertCodexRefusesWithoutSpawning(configuration: empty, decoyRelativePath: "codex")
        try assertCodexRefusesWithoutSpawning(configuration: configuration, decoyRelativePath: "codex")
        try assertCodexRefusesWithoutSpawning(configuration: configuration, decoyRelativePath: "relbin/codex")
    }

    func testStartResolvesCodexInstalledIntoFallbackDirectoryAfterARefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-center-codex-later-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("fallback-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("launched")
        let configuration = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: root,
            fallbackDirectories: [fallback.path]
        )
        let bridge = NativeCodexBridge(repoRoot: root, probeConfiguration: configuration, turnTimeout: 1, requestTimeout: 2, shutdownGrace: 0.1)
        defer { bridge.shutdown() }

        XCTAssertThrowsError(try bridge.status()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Codex"), message)
            XCTAssertTrue(message.contains("DASHBOARD_CODEX_BIN"), message)
            XCTAssertFalse(message.contains("could not complete startup"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let codex = fallback.appendingPathComponent("codex")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$0\" > '\(marker.path)'\nexit 0\n"
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        XCTAssertEqual(try NativeCodexBridge.resolveCodexCommand(configuration: configuration), codex.path)
        XCTAssertThrowsError(try bridge.status()) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not complete startup"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("was not found"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines), codex.path)
    }

    private func assertCodexRefusesWithoutSpawning(
        configuration: ToolProbeConfiguration,
        decoyRelativePath: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-center-codex-refuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("spawned-marker")
        if let decoyRelativePath {
            let decoy = root.appendingPathComponent(decoyRelativePath)
            try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = "#!/bin/sh\nprintf '%s\\n' \"$0\" > '\(marker.path)'\nexit 0\n"
            try Data(script.utf8).write(to: decoy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoy.path)
        }
        let bridge = NativeCodexBridge(repoRoot: root, probeConfiguration: configuration, turnTimeout: 1, requestTimeout: 0.5, shutdownGrace: 0.05)
        defer { bridge.shutdown() }
        let expected = ToolProbe.missingToolMessage(ToolProbe.resolve(.codex, configuration: configuration), action: "Codex")
        XCTAssertTrue(expected.contains("Codex"), expected, file: file, line: line)
        XCTAssertTrue(expected.contains("DASHBOARD_CODEX_BIN"), expected, file: file, line: line)
        XCTAssertThrowsError(try bridge.status(), file: file, line: line) { error in
            XCTAssertEqual(error as? DashboardAPIError, .serverUnavailable(expected), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("could not complete startup"), error.localizedDescription, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Codex spawn wrote \(marker.path)", file: file, line: line)
    }

    private func makeFixture() throws -> (root: URL, package: URL, stagingParent: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-center-broker-tests-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("applications/example", isDirectory: true)
        let stagingParent = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)
        try Data("original posting".utf8).write(to: package.appendingPathComponent("posting.md"))
        try Data("keep".utf8).write(to: package.appendingPathComponent("artifact.json"))
        return (root, package, stagingParent)
    }
}

private final class CodexCommandPathRecorder: @unchecked Sendable {
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
