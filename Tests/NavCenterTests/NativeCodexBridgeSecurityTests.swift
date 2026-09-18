import Foundation
import Darwin
import XCTest
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
