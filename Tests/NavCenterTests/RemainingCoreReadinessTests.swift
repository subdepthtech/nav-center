import Foundation
import SQLite3
import XCTest
@testable import NavCenterCore

final class RemainingCoreReadinessTests: XCTestCase {
    func testPackagedCLIRequiresConfirmationAndRestoresCleanup() throws {
        let f = try fixture()
        let name = "2020-01-01_Example_Engineer"
        let package = f.root.appendingPathComponent("applications/" + name)
        try FileManager.default.moveItem(at: f.package, to: package)
        let cleaner = PackageCleanup(repoRoot: f.root)
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        let result = try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: false, confirmed: true, expectedPreview: preview)
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("navcenterctl")
        let arguments = ["restore-cleanup", "--workspace", f.root.path, "--manifest", result.manifestURL.path]
        let denied = try ProcessRunner.run(binary.path, arguments)
        XCTAssertNotEqual(denied.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        let restored = try ProcessRunner.run(binary.path, arguments + ["--confirm"])
        XCTAssertEqual(restored.status, 0, restored.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("posting.md").path))
        XCTAssertTrue(restored.stdout.contains("Restored 1 package"))
    }

    private func fixture() throws -> (root: URL, package: URL, vault: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-final-core-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        let package = root.appendingPathComponent("applications/example", isDirectory: true)
        let vault = base.appendingPathComponent("vault", isDirectory: true)
        try WorkspaceManager(workspaceRoot: root).initialize()
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("---\ncompany: Synthetic\nrole: Engineer\n---\nRequired experience developing reliable tools. Responsibilities include testing.".utf8).write(to: package.appendingPathComponent("posting.md"))
        try Data("# Resume\nBuilt synthetic tools and improved test coverage.".utf8).write(to: package.appendingPathComponent("Resume_example.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, package, vault)
    }

    func testCSVPreservesNullAndEmptyCellsWithoutShiftingLaterFields() throws {
        let f = try fixture()
        _ = try TrackerStore(repoRoot: f.root).updateStatus(packageName: "example", status: .submitted)
        let dbURL = f.root.appendingPathComponent("tracking/applications.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE applications SET date='2026-09-04', company='Synthetic', position='Engineer', apply_link=NULL, resume_files='', cover_letter_files=NULL, notes='Quoted, café', next_action_date='2026-10-01'", nil, nil, nil), SQLITE_OK)
        let rows = try TrackerCSV.load(dbPath: dbURL, repoRoot: f.root)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].applyLink, "")
        XCTAssertEqual(rows[0].resumeFiles, "")
        XCTAssertEqual(rows[0].coverLetterFiles, "")
        XCTAssertEqual(rows[0].notes, "Quoted, café")
        XCTAssertEqual(rows[0].nextActionDate, "2026-10-01")
        XCTAssertTrue(TrackerCSV.serialize(rows).contains(",Engineer,,,,Submitted,\"Quoted, café\",2026-10-01"))
    }

    func testInterviewPrepUsesReviewedSourcesWithoutInventedCredentials() throws {
        let f = try fixture()
        let generator = InterviewPrepGenerator(repoRoot: URL(fileURLWithPath: f.root.path, isDirectory: false))
        let result = try generator.create(applicationPath: "applications/example", dryRun: false, overwrite: false)
        let content = try String(contentsOf: result.outputURL)
        XCTAssertTrue(content.contains("Built synthetic tools"))
        XCTAssertTrue(content.contains("only when supported by reviewed source records"))
        XCTAssertFalse(content.contains("TS/SCI"))
        XCTAssertFalse(content.contains("I am a cleared"))
        XCTAssertThrowsError(try generator.create(applicationPath: "applications/example", dryRun: false, overwrite: false))
        XCTAssertEqual(try String(contentsOf: result.outputURL), content)
    }

    func testVaultFailurePreservesPriorMirrorAndOutsideFile() throws {
        let f = try fixture()
        let target = f.vault.appendingPathComponent("applications/example", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("previous posting".utf8).write(to: target.appendingPathComponent("posting.md"))
        let outside = f.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("outside canary".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("Resume_example.md"), withDestinationURL: outside)
        XCTAssertThrowsError(try VaultSync(repoRoot: f.root, vaultRoot: f.vault).sync(applicationPath: "applications/example"))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("posting.md")), "previous posting")
        XCTAssertEqual(try String(contentsOf: outside), "outside canary")
    }

    func testVaultSuccessfulCopyAndSourceAliasFailurePreservePriorSet() throws {
        let f = try fixture()
        let sync = VaultSync(repoRoot: URL(fileURLWithPath: f.root.path, isDirectory: false), vaultRoot: f.vault)
        let first = try sync.sync(applicationPath: "applications/example")
        XCTAssertEqual(first.copiedCount, 2)
        let prior = try Data(contentsOf: first.targetURL.appendingPathComponent("posting.md"))
        try Data("new posting".utf8).write(to: f.package.appendingPathComponent("posting.md"))
        let outside = f.root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.package.appendingPathComponent("artifacts"), withDestinationURL: outside)
        XCTAssertThrowsError(try sync.sync(applicationPath: "applications/example"))
        XCTAssertEqual(try Data(contentsOf: first.targetURL.appendingPathComponent("posting.md")), prior)
    }
}
