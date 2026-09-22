import Foundation
import XCTest
import SQLite3
import Darwin
@testable import NavCenterCore

final class CoreDataIntegrityTests: XCTestCase {
    private var root: URL!
    private let packageName = "2020-01-01_Example_Engineer"
    private var database: URL { root.appendingPathComponent("tracking/applications.sqlite") }
    private var package: URL { root.appendingPathComponent("applications/" + packageName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nav-center-integrity-" + UUID().uuidString)
        try WorkspaceManager(workspaceRoot: root).initialize()
        try makePackage(packageName)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makePackage(_ name: String) throws {
        let directory = root.appendingPathComponent("applications/" + name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try put("---\ncompany: Example\nrole: Engineer\n---\nResponsibilities include secure delivery and testing. Required experience in engineering.", directory.appendingPathComponent("posting.md"))
    }

    private func put(_ text: String, _ path: URL) throws {
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func status(_ value: TrackerStatus = .submitted, packageName name: String? = nil) throws -> TrackerStatusUpdateResult {
        try TrackerStore(repoRoot: root).updateStatus(packageName: name ?? packageName, status: value)
    }

    private func cleanup() throws -> PackageCleanupResult {
        let cleaner = PackageCleanup(repoRoot: root)
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        return try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: true, confirmed: true, expectedPreview: preview)
    }

    func testFirstStatusActionCreatesTrackerAndOneHistoryEvent() throws {
        XCTAssertFalse(SQLiteSupport.exists(database))
        let result = try status()
        XCTAssertEqual(result.oldStatus, "")
        XCTAssertEqual(result.newStatus, "Submitted")
        XCTAssertTrue(result.warnings.isEmpty)
        let rows = try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["new_status"] as? String, "Submitted")
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 1)
    }

    func testStatusChangeRefusesTrackerIDCollisionWithoutMutatingSibling() throws {
        let first = "2099-01-01_A-B_Role"
        let second = "2099-01-01_A_B_Role"
        try makePackage(first)
        try makePackage(second)
        _ = try status(.submitted, packageName: first)

        XCTAssertThrowsError(try status(.interview, packageName: second)) { error in
            XCTAssertTrue(error.localizedDescription.contains(first), error.localizedDescription)
        }

        let rows = try TrackerStore(repoRoot: root).loadRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.applicationDir, "applications/" + first)
        XCTAssertEqual(rows.first?.status, "Submitted")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 1)
    }

    func testStatusChangeBindsExistingRowByApplicationDirectoryNotID() throws {
        _ = try status()
        let legacyPackage = "2020-02-02_Legacy_Engineer"
        try makePackage(legacyPackage)
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO applications (id, application_dir, status) VALUES ('legacy', 'applications/\(legacyPackage)', 'Submitted');")

        let result = try status(.interview, packageName: legacyPackage)

        XCTAssertEqual(result.applicationID, "legacy")
        let rows = try TrackerStore(repoRoot: root).loadRows().filter { $0.applicationDir == "applications/" + legacyPackage }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "legacy")
        XCTAssertEqual(rows.first?.status, "Interview")
    }

    func testStatusChangeRefusesDuplicateApplicationDirectoryRows() throws {
        _ = try status()
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO applications (id, application_dir, status) VALUES ('duplicate', 'applications/\(packageName)', 'Not Pursuing');")

        XCTAssertThrowsError(try status(.interview))

        let rows = try TrackerStore(repoRoot: root).loadRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "2020_01_01_example_engineer" })?.status, "Submitted")
        XCTAssertEqual(rows.first(where: { $0.id == "duplicate" })?.status, "Not Pursuing")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 1)
    }

    func testStatusChangeCollisionWithDirectorylessRowNamesMissingDirectory() throws {
        _ = try status()
        let orphanPackage = "2020-03-03_Orphan_Engineer"
        try makePackage(orphanPackage)
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO applications (id, application_dir, status) VALUES ('2020_03_03_orphan_engineer', '', 'Submitted');")

        XCTAssertThrowsError(try status(.interview, packageName: orphanPackage)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no application directory"), error.localizedDescription)
        }

        let rows = try TrackerStore(repoRoot: root).loadRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "2020_03_03_orphan_engineer" })?.status, "Submitted")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 1)
    }

    func testStatusEventFailureRollsBackStatus() throws {
        _ = try status()
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "CREATE TRIGGER refuse_event BEFORE INSERT ON status_events BEGIN SELECT RAISE(ABORT, 'fixture event failure'); END;")
        XCTAssertThrowsError(try status(.interview))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().first?.status, "Submitted")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 1)
    }

    func testSnapshotFailureReportsCommittedStatus() throws {
        _ = try status()
        let snapshot = root.appendingPathComponent("tracking/applications.md")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        let result = try status(.interview)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().first?.status, "Interview")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 2)
    }

    func testUnsupportedExistingSchemaIsNotReplaced() throws {
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "CREATE TABLE retained (value TEXT); INSERT INTO retained VALUES ('keep'); PRAGMA user_version=99;")
        XCTAssertThrowsError(try status())
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select value from retained;").first?["value"] as? String, "keep")
    }

    func testTrackerRejectsDatabaseAndSidecarAliases() throws {
        _ = try status()
        let outside = root.appendingPathComponent("outside.sqlite")
        try FileManager.default.moveItem(at: database, to: outside)
        let original = try Data(contentsOf: outside)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: outside)
        XCTAssertThrowsError(try status(.interview))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        try FileManager.default.removeItem(at: database)
        XCTAssertEqual(link(outside.path, database.path), 0)
        XCTAssertThrowsError(try status(.interview))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: outside, to: database)
        let sentinel = root.appendingPathComponent("outside-sidecar")
        try put("untouched", sentinel)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: database.path + "-wal"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try status(.interview))
        XCTAssertEqual(try String(contentsOf: sentinel), "untouched")
    }

    func testCleanupRequiresPreviewAndRejectsChangedContents() throws {
        let cleaner = PackageCleanup(repoRoot: root)
        XCTAssertThrowsError(try cleaner.apply(olderThanDays: 7, today: "2026-09-04", deleteTracked: true, confirmed: true))
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        try put("user's new posting", package.appendingPathComponent("posting.md"))
        XCTAssertThrowsError(try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: true, confirmed: true, expectedPreview: preview))
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("posting.md")), "user's new posting")
    }

    func testCleanupNewCandidateRequiresReconfirmation() throws {
        let cleaner = PackageCleanup(repoRoot: root)
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        try makePackage("2020-02-01_Other_Engineer")
        XCTAssertThrowsError(try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: true, confirmed: true, expectedPreview: preview))
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertTrue(SQLiteSupport.exists(root.appendingPathComponent("applications/2020-02-01_Other_Engineer")))
    }

    func testCleanupMissingArtifactsTableLeavesPackages() throws {
        _ = try status()
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "DROP TABLE artifacts;")
        XCTAssertThrowsError(try cleanup())
        XCTAssertTrue(SQLiteSupport.exists(package.appendingPathComponent("posting.md")))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 1)
    }

    func testCleanupDuplicateTrackerDirectoryRejectedBeforeRemoval() throws {
        _ = try status()
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO applications (id, application_dir, status) VALUES ('duplicate', 'applications/\(packageName)', 'Submitted');")
        XCTAssertThrowsError(try cleanup())
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 2)
    }

    func testCleanupDeleteFailureRollsBackAllMovedPackages() throws {
        _ = try status()
        let other = "2020-02-01_Other_Engineer"
        try makePackage(other)
        _ = try status(packageName: other)
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON applications BEGIN SELECT RAISE(ABORT, 'fixture delete failure'); END;")
        XCTAssertThrowsError(try cleanup())
        XCTAssertTrue(SQLiteSupport.exists(package.appendingPathComponent("posting.md")))
        XCTAssertTrue(SQLiteSupport.exists(root.appendingPathComponent("applications/" + other + "/posting.md")))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 2)
    }

    func testCleanupRestoreRoundTripPreservesEveryPackageFileAndOtherTracking() throws {
        _ = try status()
        let artifact = package.appendingPathComponent("artifacts/nested/document.bin")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 255]).write(to: artifact)
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO artifacts VALUES ('2020_01_01_example_engineer', 'artifacts/nested/document.bin');")
        let before = try Data(contentsOf: package.appendingPathComponent("posting.md"))
        let result = try cleanup()
        XCTAssertFalse(SQLiteSupport.exists(package))
        XCTAssertTrue(try TrackerStore(repoRoot: root).loadRows().isEmpty)
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: result.backupURL, sql: "select * from applications;").count, 1)
        let other = "2099-01-01_New_Engineer"
        try makePackage(other)
        _ = try status(packageName: other)
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertEqual(try Data(contentsOf: artifact), Data([0, 1, 2, 255]))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("posting.md")), before)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 2)
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from artifacts;").count, 1)
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
    }

    func testUntrackedCleanupRestoreDoesNotCreateTracker() throws {
        let result = try cleanup()
        XCTAssertFalse(SQLiteSupport.exists(database))
        XCTAssertFalse(SQLiteSupport.exists(package))
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertFalse(SQLiteSupport.exists(database))
    }

    func testRestoreResultSeparatesMovedPackagesFromAlreadyPresentPackages() throws {
        let applied = try cleanup()
        XCTAssertEqual(applied.removedPackages.map(\.packageName), [packageName])
        XCTAssertTrue(applied.restoredPackages.isEmpty)

        let cleaner = PackageCleanup(repoRoot: root)
        cleaner.beforeManifestWrite = { state, _ in
            if state == "restored" { throw NavCenterError.commandFailed("fixture restore manifest failure") }
        }
        let firstRestore = try cleaner.restore(manifestURL: applied.manifestURL, confirmed: true)
        XCTAssertTrue(firstRestore.removedPackages.isEmpty)
        XCTAssertEqual(firstRestore.restoredPackages.map(\.packageName), [packageName])

        let retry = try PackageCleanup(repoRoot: root).restore(manifestURL: applied.manifestURL, confirmed: true)
        XCTAssertTrue(retry.removedPackages.isEmpty)
        XCTAssertTrue(retry.restoredPackages.isEmpty)
    }

    func testRestoreResultReportsTrackerRowsRestoredAfterPackagesWereAlreadyMoved() throws {
        _ = try status()
        let applied = try cleanup()
        let retained = applied.manifestURL.deletingLastPathComponent()
            .appendingPathComponent("packages/" + packageName, isDirectory: true)
        try PathSafety.moveItem(retained, to: package, inside: root, label: "synthetic interrupted restore")

        let restored = try PackageCleanup(repoRoot: root).restore(manifestURL: applied.manifestURL, confirmed: true)

        XCTAssertTrue(restored.removedPackages.isEmpty)
        XCTAssertTrue(restored.restoredPackages.isEmpty)
        XCTAssertEqual(restored.restoredTrackerRows, 2)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().map(\.applicationDir), ["applications/" + packageName])
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, 1)
    }

    func testCleanupBackupIncludesCommittedWALRows() throws {
        _ = try status()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL; UPDATE applications SET status='Interview';", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(SQLiteSupport.exists(URL(fileURLWithPath: database.path + "-wal")))
        let result = try cleanup()
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: result.backupURL, sql: "select status from applications;").first?["status"] as? String, "Interview")
    }

    func testInvalidImportBatchLeavesNoOriginalsOrManifest() throws {
        let good = root.appendingPathComponent("good.txt")
        let bad = root.appendingPathComponent("bad.txt")
        try put("a readable document", good)
        try Data([0xff, 0xfe, 0x01]).write(to: bad)
        XCTAssertThrowsError(try DocumentImporter(workspaceRoot: root).importDocuments([good, bad]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("imports/originals").path).isEmpty)
        XCTAssertFalse(SQLiteSupport.exists(root.appendingPathComponent("imports/manifest.jsonl")))
        XCTAssertEqual(try Data(contentsOf: bad), Data([0xff, 0xfe, 0x01]))
    }

    func testImportManifestAliasBlocksAllOutputsAndPreservesOutside() throws {
        let source = root.appendingPathComponent("source.txt")
        let sentinel = root.appendingPathComponent("outside-manifest")
        try put("document contents", source)
        try put("outside unchanged", sentinel)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("imports/manifest.jsonl"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try DocumentImporter(workspaceRoot: root).importDocuments([source]))
        XCTAssertEqual(try String(contentsOf: sentinel), "outside unchanged")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("imports/originals").path).isEmpty)
    }

    func testRepeatedImportsHaveMatchingUniqueNamesAndManifestEntries() throws {
        let source = root.appendingPathComponent("source.txt")
        try put("document contents", source)
        let results = try DocumentImporter(workspaceRoot: root).importDocuments([source, source])
        XCTAssertEqual(results.map(\.originalRelativePath), ["imports/originals/source.txt", "imports/originals/source_1.txt"])
        XCTAssertEqual(results.map(\.markdownRelativePath), ["imports/markdown/source.md", "imports/markdown/source_1.md"])
        let manifest = try String(contentsOf: root.appendingPathComponent("imports/manifest.jsonl"))
        XCTAssertEqual(manifest.split(separator: "\n").count, 2)
    }

    func testCoordinatedOutputsRollBackEarlierReplacementWhenLaterWriteFails() throws {
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try put("first original", first)
        try put("second original", second)
        XCTAssertEqual(chflags(second.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(second.path, 0) }
        XCTAssertThrowsError(try CoreFileSetCommit.apply([(first, Data("first new".utf8)), (second, Data("second new".utf8))], inside: root))
        XCTAssertEqual(try String(contentsOf: first), "first original")
        XCTAssertEqual(try String(contentsOf: second), "second original")
    }

    func testConcurrentStatusHistoryUsesCommittedOldStatus() throws {
        _ = try status()
        let results = ErrorCollector()
        let group = DispatchGroup()
        let workspace = root!
        let name = packageName
        for next in [TrackerStatus.interview, .notPursuing] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try TrackerStore(repoRoot: workspace).updateStatus(packageName: name, status: next) }
                catch { results.add(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(results.values.isEmpty, "\(results.values)")
        let events = try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events order by rowid;")
        XCTAssertEqual(events.count, 3)
        if events.count == 3 {
            XCTAssertEqual(events[1]["old_status"] as? String, "Submitted")
            XCTAssertEqual(events[2]["old_status"] as? String, events[1]["new_status"] as? String)
            let currentStatus = try TrackerStore(repoRoot: root).loadRows().first!.status
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("tracking/applications.md")).contains("| " + currentStatus + " |"))
        }
    }

    func testInvalidKitFinalTargetLeavesAllOutputsUnchangedAndRetryWorks() throws {
        let prompt = package.appendingPathComponent("interview-review-prompt.md")
        try FileManager.default.createDirectory(at: prompt, withIntermediateDirectories: false)
        let generator = RealtimeInterviewKitGenerator(repoRoot: root)
        XCTAssertThrowsError(try generator.create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true))
        XCTAssertFalse(SQLiteSupport.exists(package.appendingPathComponent("interview-realtime-session.json")))
        XCTAssertFalse(SQLiteSupport.exists(package.appendingPathComponent("interview-transcript.md")))
        try FileManager.default.removeItem(at: prompt)
        let result = try generator.create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertTrue(result.wroteFiles)
        let transcript = package.appendingPathComponent("interview-transcript.md")
        try put("user's interview transcript", transcript)
        _ = try generator.create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertEqual(try String(contentsOf: transcript), "user's interview transcript")
    }

    func testMalformedPackageDoesNotHideHealthyPackages() throws {
        let bad = "2020-02-01_Broken_Engineer"
        try makePackage(bad)
        let posting = root.appendingPathComponent("applications/" + bad + "/posting.md")
        try FileManager.default.removeItem(at: posting)
        try FileManager.default.createDirectory(at: posting, withIntermediateDirectories: false)
        let result = try PackageInspector(repoRoot: root).scanWithWarnings()
        XCTAssertEqual(result.packages.map(\.name), [packageName])
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testWrongTypeApplicationsRootReportsError() throws {
        let applications = root.appendingPathComponent("applications")
        try FileManager.default.removeItem(at: applications)
        try put("wrong type", applications)
        XCTAssertThrowsError(try PackageInspector(repoRoot: root).scan())
    }

    func testATSExitZeroWithoutFreshValidOutputFailsAndValidOutputSucceeds() throws {
        try put("# Synthetic Candidate\nSkills: engineering and testing.", package.appendingPathComponent("Resume_Synthetic.md"))
        let runner = PackageActionRunner(repoRoot: root)
        let missing = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, _, _, _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        XCTAssertEqual(missing.status, "failed")
        let invalid = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try self.put("invalid JSON", cwd.appendingPathComponent(args[3]))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(invalid.status, "failed")
        let valid = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, args, cwd, _ in
            try self.put("{\"scores\":{\"overall\":92},\"warnings\":[]}", cwd.appendingPathComponent(args[3]))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        XCTAssertEqual(valid.status, "succeeded")
        let unchanged = try runner.run(packageName: packageName, actionKey: "ats-scan", confirmed: true) { _, _, _, _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        XCTAssertEqual(unchanged.status, "failed")
    }

    func testInterviewGeneratorsReadCanonicalAndLegacyATSScores() throws {
        let artifacts = package.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let reports = [
            "{\"scores\":{\"overall\":92},\"warnings\":[\"Synthetic warning\"]}",
            "{\"scores\":{\"overall\":92},\"score\":61}",
            "{\"score\":92}", "{\"overall_score\":92}", "{\"summary\":{\"score\":92}}"
        ]
        for report in reports {
            try put(report, artifacts.appendingPathComponent("ats-report.json"))
            let prep = try InterviewPrepGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
            XCTAssertTrue(try String(contentsOf: prep.outputURL).contains("ATS report found: score 92;"), report)
            let kit = try RealtimeInterviewKitGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
            XCTAssertTrue(try String(contentsOf: kit.sessionConfigURL).contains("ATS score 92."), report)
        }
        try put("invalid JSON", artifacts.appendingPathComponent("ats-report.json"))
        let prep = try InterviewPrepGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertTrue(try String(contentsOf: prep.outputURL).contains("No ATS report found"))
        let kit = try RealtimeInterviewKitGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertTrue(try String(contentsOf: kit.sessionConfigURL).contains("No ATS report found"))
    }

    func testInterviewGeneratorsIgnoreOversizedATSReports() throws {
        try FileManager.default.createDirectory(at: package.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        try put("{\"scores\":{\"overall\":92},\"padding\":\"" + String(repeating: "x", count: 4 * 1024 * 1024) + "\"}", package.appendingPathComponent("artifacts/ats-report.json"))
        let prep = try InterviewPrepGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertTrue(try String(contentsOf: prep.outputURL).contains("No ATS report found"))
        let kit = try RealtimeInterviewKitGenerator(repoRoot: root).create(applicationPath: "applications/" + packageName, dryRun: false, overwrite: true)
        XCTAssertTrue(try String(contentsOf: kit.sessionConfigURL).contains("No ATS report found"))
    }

    func testRefreshExitZeroWithoutPDFFails() throws {
        let result = try PackageActionRunner(repoRoot: root).run(packageName: packageName, actionKey: "refresh-resume", confirmed: true) { _, _, _, _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        XCTAssertEqual(result.status, "failed")
    }

    func testFailedExportPreservesPreviousArtifactSetAndSuccessfulExportReplacesAll() throws {
        let source = package.appendingPathComponent("Resume_" + packageName + ".md")
        try put("# Candidate\nA sufficiently detailed synthetic engineering resume.", source)
        let templates = root.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try put("body { color: black; }", templates.appendingPathComponent("resume.css"))
        let artifacts = package.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let base = source.deletingPathExtension().lastPathComponent
        let extensions = ["html", "docx", "pdf", "docx.txt", "pdf.txt"]
        for ext in extensions { try put("OLD-" + ext, artifacts.appendingPathComponent(base + "." + ext)) }
        let tools = try makeExportTools(chromeFails: true)
        XCTAssertThrowsError(try ArtifactExporter(repoRoot: root, environment: tools).export(markdownPaths: ["applications/" + packageName + "/" + source.lastPathComponent]))
        for ext in extensions { XCTAssertEqual(try String(contentsOf: artifacts.appendingPathComponent(base + "." + ext)), "OLD-" + ext) }
        let success = try makeExportTools(chromeFails: false)
        let result = try ArtifactExporter(repoRoot: root, environment: success).export(markdownPaths: ["applications/" + packageName + "/" + source.lastPathComponent])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(try Data(contentsOf: result[0].pdfURL).starts(with: Data("%PDF-".utf8)))
        XCTAssertTrue(try String(contentsOf: result[0].docxTextURL).contains("synthetic"))
    }

    func testExportExtractionFailurePreservesPriorSet() throws {
        let source = package.appendingPathComponent("Resume_" + packageName + ".md")
        try put("A sufficiently detailed synthetic engineering resume.", source)
        let relative = "applications/" + packageName + "/" + source.lastPathComponent
        let goodTools = try makeExportTools(chromeFails: false)
        let first = try ArtifactExporter(repoRoot: root, environment: goodTools).export(markdownPaths: [relative])[0]
        let outputs = [first.htmlURL, first.docxURL, first.pdfURL, first.docxTextURL, first.pdfTextURL]
        let original = try outputs.map { try Data(contentsOf: $0) }
        let badTools = try makeExportTools(chromeFails: false)
        try put("#!/bin/sh\nif [ \"$1\" = \"-v\" ]; then exit 0; fi\nprintf 'short'\n", URL(fileURLWithPath: badTools["PDFTOTEXT_BIN"]!))
        XCTAssertThrowsError(try ArtifactExporter(repoRoot: root, environment: badTools).export(markdownPaths: [relative]))
        XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) }, original)
    }

    func testExportSecondInputFailureExplicitlyReportsCompletedDocuments() throws {
        let source = package.appendingPathComponent("Resume_" + packageName + ".md")
        try put("A sufficiently detailed synthetic engineering resume.", source)
        let tools = try makeExportTools(chromeFails: false)
        do {
            _ = try ArtifactExporter(repoRoot: root, environment: tools).export(markdownPaths: ["applications/" + packageName + "/" + source.lastPathComponent, "resumes/missing.md"])
            XCTFail("Expected a partial-batch error")
        } catch let error as ArtifactExportBatchError {
            XCTAssertEqual(error.completed.count, 1)
            XCTAssertEqual(error.failedInput, "resumes/missing.md")
            XCTAssertTrue(SQLiteSupport.exists(try XCTUnwrap(error.completed.first).pdfURL))
        }
    }

    func testRecoveryRefusesBackupWhileCleanupStillOwnsEvidenceLease() throws {
        _ = try status()
        let cleaner = PackageCleanup(repoRoot: root)
        var refusal: String?
        cleaner.beforeManifestWrite = { state, manifest in
            if state == "completed" {
                do { _ = try PackageCleanup(repoRoot: self.root).restore(manifestURL: manifest, confirmed: true) }
                catch { refusal = error.localizedDescription }
            }
        }
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        let result = try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: true, confirmed: true, expectedPreview: preview)
        XCTAssertTrue(refusal?.contains("still active") == true)
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package))
    }

    func testPreparedRecoveryAfterCommittedDeleteAndFailedManifestUpdate() throws {
        _ = try status()
        let cleaner = PackageCleanup(repoRoot: root)
        cleaner.beforeManifestWrite = { state, _ in
            if state == "completed" { throw NavCenterError.commandFailed("fixture final manifest write failure") }
        }
        let preview = try cleaner.preview(olderThanDays: 7, today: "2026-09-04")
        let result = try cleaner.apply(olderThanDays: 7, today: preview.today, deleteTracked: true, confirmed: true, expectedPreview: preview)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try manifestObject(result)["state"] as? String, "prepared")
        XCTAssertEqual(try manifestObject(result)["backupReady"] as? Bool, true)
        let other = "2099-01-01_Later_Engineer"
        try makePackage(other)
        _ = try status(.interview, packageName: other)
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package.appendingPathComponent("posting.md")))
        let rows = try TrackerStore(repoRoot: root).loadRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.applicationDir == "applications/" + other })?.status, "Interview")
        XCTAssertEqual(try manifestObject(result)["state"] as? String, "restored")
    }

    func testPreparedRecoveryRestoresPartialMovesAfterUncommittedSQLiteRollback() throws {
        _ = try status()
        let other = "2020-02-01_Other_Engineer"
        try makePackage(other)
        _ = try status(packageName: other)
        let result = try cleanup()
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        try updateManifest(result) { $0["state"] = "prepared" }
        let retained = result.manifestURL.deletingLastPathComponent().appendingPathComponent("packages/" + packageName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE; DELETE FROM artifacts; DELETE FROM status_events; DELETE FROM applications;", nil, nil, nil), SQLITE_OK)
        try FileManager.default.moveItem(at: package, to: retained)
        // Closing an uncommitted connection models SQLite recovery on process
        // termination; only one package move has reached the filesystem.
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 2)
        let later = "2099-01-01_Later_Engineer"
        try makePackage(later)
        _ = try status(packageName: later)
        let eventCount = try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertTrue(SQLiteSupport.exists(root.appendingPathComponent("applications/" + other)))
        XCTAssertFalse(SQLiteSupport.exists(retained))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 3)
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, eventCount)
    }

    func testPreparedRecoveryHandlesInterruptedRestoreBeforeTrackerCommit() throws {
        _ = try status()
        let other = "2020-02-01_Other_Engineer"
        try makePackage(other)
        _ = try status(packageName: other)
        let result = try cleanup()
        try updateManifest(result) { $0["state"] = "prepared" }
        // Restore previously moved this package, but its SQLite transaction
        // did not commit. The other package remains in the retained location.
        let retained = result.manifestURL.deletingLastPathComponent().appendingPathComponent("packages/" + packageName)
        try FileManager.default.moveItem(at: retained, to: package)
        XCTAssertTrue(try TrackerStore(repoRoot: root).loadRows().isEmpty)
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertTrue(SQLiteSupport.exists(root.appendingPathComponent("applications/" + other)))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 2)
    }

    func testPreparedBeforeBackupLeavesIntactPackagesAndLaterTrackingUntouched() throws {
        _ = try status()
        let result = try cleanup()
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        try updateManifest(result) {
            $0["state"] = "prepared"
            $0["backupReady"] = false
            $0.removeValue(forKey: "databaseBackupDigest")
        }
        try FileManager.default.removeItem(at: result.backupURL)
        _ = try status(.interview)
        let before = try Data(contentsOf: package.appendingPathComponent("posting.md"))
        let events = try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("posting.md")), before)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().first?.status, "Interview")
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, events)
    }

    func testPreparedRecoveryRejectsConflictingCurrentTrackerRowsBeforeMovingFiles() throws {
        _ = try status()
        let result = try cleanup()
        try updateManifest(result) { $0["state"] = "prepared" }
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "INSERT INTO applications (id, application_dir, status) VALUES ('newer-id', 'applications/\(packageName)', 'Interview');")
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        XCTAssertFalse(SQLiteSupport.exists(package))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().first?.id, "newer-id")
        XCTAssertTrue(SQLiteSupport.exists(result.manifestURL.deletingLastPathComponent().appendingPathComponent("packages/" + packageName)))
    }

    func testPreparedRecoveryRejectsBothPackageLocationsAndChangedBackup() throws {
        _ = try status()
        let result = try cleanup()
        try updateManifest(result) { $0["state"] = "prepared" }
        try makePackage(packageName)
        try put("newer original", package.appendingPathComponent("posting.md"))
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("posting.md")), "newer original")
        try FileManager.default.removeItem(at: package)
        let retainedPosting = result.manifestURL.deletingLastPathComponent().appendingPathComponent("packages/" + packageName + "/posting.md")
        try put("modified backup", retainedPosting)
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        XCTAssertEqual(try String(contentsOf: retainedPosting), "modified backup")
        XCTAssertTrue(try TrackerStore(repoRoot: root).loadRows().isEmpty)
    }

    func testPreparedRecoveryRejectsChangedSQLiteBackupWithoutMovingPackages() throws {
        _ = try status()
        let result = try cleanup()
        try updateManifest(result) { $0["state"] = "prepared" }
        try SQLiteSupport.run(dbPath: result.backupURL, repoRoot: root, sql: "CREATE TABLE later_backup_edit (value TEXT); INSERT INTO later_backup_edit VALUES ('changed');")
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        XCTAssertFalse(SQLiteSupport.exists(package))
        XCTAssertTrue(try TrackerStore(repoRoot: root).loadRows().isEmpty)
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: result.backupURL, sql: "select value from later_backup_edit;").first?["value"] as? String, "changed")
    }

    func testPreparedRecoveryRejectsMixedAffectedTrackerState() throws {
        _ = try status()
        let other = "2020-02-01_Other_Engineer"
        try makePackage(other)
        _ = try status(packageName: other)
        let result = try cleanup()
        try updateManifest(result) { $0["state"] = "prepared" }
        let source = try SQLiteSupport.Connection(dbPath: result.backupURL, repoRoot: root, writable: false)
        let target = try SQLiteSupport.Connection(dbPath: database, repoRoot: root, writable: true)
        let firstID = packageName.replacingOccurrences(of: "-", with: "_").lowercased()
        for (table, column) in [("applications", "id"), ("status_events", "application_id"), ("artifacts", "application_id")] {
            for row in try source.rows("select * from \(table) where \(column) = \(SQLiteSupport.quote(firstID));") {
                let keys = row.keys.sorted()
                try target.execute("insert into \(table) (\(keys.map(SQLiteSupport.identifier).joined(separator: ","))) values (\(keys.map { SQLiteSupport.literal(row[$0]!) }.joined(separator: ",")));")
            }
        }
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 1)
        XCTAssertFalse(SQLiteSupport.exists(package))
        XCTAssertFalse(SQLiteSupport.exists(root.appendingPathComponent("applications/" + other)))
    }

    func testRecoveryRefusesCustomInsertTriggerThatCouldDeleteLaterRecords() throws {
        _ = try status()
        let result = try cleanup()
        let later = "2099-01-01_Later_Engineer"
        try makePackage(later)
        _ = try status(.interview, packageName: later)
        try SQLiteSupport.run(dbPath: database, repoRoot: root, sql: "CREATE TRIGGER unsafe_restore AFTER INSERT ON applications BEGIN DELETE FROM applications WHERE application_dir='applications/\(later)'; END;")
        XCTAssertThrowsError(try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true))
        let rows = try TrackerStore(repoRoot: root).loadRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.applicationDir, "applications/" + later)
        XCTAssertFalse(SQLiteSupport.exists(package))
        XCTAssertTrue(SQLiteSupport.exists(result.manifestURL.deletingLastPathComponent().appendingPathComponent("packages/" + packageName)))
    }

    func testRestoreManifestFailureCanBeRetriedWithoutDuplicateRecords() throws {
        _ = try status()
        let result = try cleanup()
        let cleaner = PackageCleanup(repoRoot: root)
        cleaner.beforeManifestWrite = { state, _ in
            if state == "restored" { throw NavCenterError.commandFailed("fixture restore manifest failure") }
        }
        let restored = try cleaner.restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertFalse(restored.warnings.isEmpty)
        XCTAssertEqual(try manifestObject(result)["state"] as? String, "completed")
        let events = try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 1)
        XCTAssertEqual(try TrackerStore.queryRows(repoRoot: root, dbPath: database, sql: "select * from status_events;").count, events)
        XCTAssertEqual(try manifestObject(result)["state"] as? String, "restored")
    }

    func testLegacyPreparedManifestRecoversOnlyValidatedAbsentRecords() throws {
        _ = try status()
        let result = try cleanup()
        try updateManifest(result) {
            $0["version"] = 1
            $0["state"] = "prepared"
            $0.removeValue(forKey: "backupReady")
            $0.removeValue(forKey: "databaseBackupDigest")
        }
        _ = try PackageCleanup(repoRoot: root).restore(manifestURL: result.manifestURL, confirmed: true)
        XCTAssertTrue(SQLiteSupport.exists(package))
        XCTAssertEqual(try TrackerStore(repoRoot: root).loadRows().count, 1)
    }

    private func manifestObject(_ result: PackageCleanupResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.manifestURL)) as? [String: Any])
    }

    private func updateManifest(_ result: PackageCleanupResult, change: (inout [String: Any]) -> Void) throws {
        var object = try manifestObject(result)
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: result.manifestURL, options: .atomic)
    }

    private func makeExportTools(chromeFails: Bool) throws -> [String: String] {
        let directory = root.appendingPathComponent("fake-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pandoc = directory.appendingPathComponent("pandoc")
        let chrome = directory.appendingPathComponent("chrome")
        let extract = directory.appendingPathComponent("pdftotext")
        try put("""
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
        """, pandoc)
        try put(chromeFails ? "#!/bin/sh\nexit 17\n" : """
        #!/bin/sh
        for value in "$@"; do
          case "$value" in --print-to-pdf=*) output="${value#--print-to-pdf=}" ;; esac
        done
        printf '%%PDF-1.7 synthetic document' > "$output"
        """, chrome)
        try put("#!/bin/sh\nif [ \"$1\" = \"-v\" ]; then exit 0; fi\nprintf 'A complete synthetic PDF extraction for validation.'\n", extract)
        for file in [pandoc, chrome, extract] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        return ["PANDOC_BIN": pandoc.path, "CHROME_BIN": chrome.path, "PDFTOTEXT_BIN": extract.path, "NAV_CENTER_SKIP_VAULT_SYNC": "1"]
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error.localizedDescription) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return errors }
}
