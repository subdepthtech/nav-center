import XCTest
import Darwin
import struct NavCenterCore.CreateApplicationResult
import struct NavCenterCore.MasterResumeSaveResult
import struct NavCenterCore.MasterResumeSnapshot
import enum NavCenterCore.TrackerStatus
import struct NavCenterCore.TrackerStatusUpdateResult
import struct NavCenterCore.PackageCleanupCandidate
import struct NavCenterCore.PackageCleanupPreview
import struct NavCenterCore.PackageCleanupResult
import struct NavCenterCore.ImportedDocument
import class NavCenterCore.MasterResumeStore
import class NavCenterCore.WorkspaceManager
import struct NavCenterCore.ToolProbeConfiguration
import enum NavCenterCore.NavCenterError
@testable import NavCenterApp


final class UXReadinessTests: XCTestCase {
    @MainActor
    func testLateCodexReplyStaysWithOriginalPackageAndThread() async throws {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        let started = expectation(description: "A turn started")
        let release = DispatchSemaphore(value: 0)
        service.chatStarted = started
        service.chatRelease = release
        let task = Task { await store.sendCodexMessage("A context", allowEdits: false, confirmed: false) }
        await fulfillment(of: [started], timeout: 2)
        await store.loadPackage(named: "B")
        release.signal()
        await task.value
        XCTAssertEqual(store.selectedPackage?.package.name, "B")
        XCTAssertNil(store.codexThreadId)
        XCTAssertTrue(store.codexMessages.isEmpty)
        await store.loadPackage(named: "A")
        XCTAssertEqual(store.codexThreadId, "thread_A")
        XCTAssertEqual(store.codexMessages.map(\.role), [.user, .assistant])
        service.chatStarted = nil
        service.chatRelease = nil
        await store.loadPackage(named: "B")
        await store.sendCodexMessage("B context", allowEdits: false, confirmed: false)
        XCTAssertEqual(service.sentCodexRequests.last?.packageName, "B")
        XCTAssertNil(service.sentCodexRequests.last?.threadId)
    }

    @MainActor
    func testLateCodexFailureDoesNotPublishInAnotherPackage() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        let started = expectation(description: "A turn started")
        let release = DispatchSemaphore(value: 0)
        service.chatStarted = started
        service.chatRelease = release
        service.chatError = DashboardAPIError.serverUnavailable("Synthetic A failure")
        let task = Task { await store.sendCodexMessage("A context", allowEdits: true, confirmed: true) }
        await fulfillment(of: [started], timeout: 2)
        await store.loadPackage(named: "B")
        release.signal()
        await task.value
        XCTAssertNil(store.codexErrorMessage)
        XCTAssertTrue(store.codexMessages.isEmpty)
        await store.loadPackage(named: "A")
        XCTAssertEqual(store.codexMessages.last?.text, "Synthetic A failure")
    }

    @MainActor
    func testInterviewReviewRequiresExplicitApprovalAndAuthentication() async throws {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        await store.reviewRealtimeInterviewWithCodex()
        XCTAssertTrue(service.sentCodexRequests.isEmpty)
        await store.reviewRealtimeInterviewWithCodex(confirmed: true, packageName: "A")
        XCTAssertTrue(service.sentCodexRequests.isEmpty)
        store.codexStatus = try service.fetchCodexStatus()
        await store.reviewRealtimeInterviewWithCodex(confirmed: true, packageName: "B")
        XCTAssertTrue(service.sentCodexRequests.isEmpty)
        await store.reviewRealtimeInterviewWithCodex(confirmed: true, packageName: "A")
        XCTAssertEqual(service.sentCodexRequests.count, 1)
        XCTAssertEqual(service.sentCodexRequests.first?.packageName, "A")
        XCTAssertEqual(service.sentCodexRequests.first?.allowEdits, true)
        XCTAssertEqual(service.sentCodexRequests.first?.confirmed, true)
    }

    @MainActor
    func testUnconfirmedDirectEditRequestIsRejected() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        await store.sendCodexMessage("Edit", allowEdits: true, confirmed: false)
        XCTAssertTrue(service.sentCodexRequests.isEmpty)
        XCTAssertNotNil(store.codexErrorMessage)
    }

    @MainActor
    func testCancellationBypassesBlockedCodexQueue() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        let started = expectation(description: "Turn started")
        let cancelled = expectation(description: "Cancellation reached blocked turn")
        service.chatStarted = started
        service.chatRelease = DispatchSemaphore(value: 0)
        service.cancelled = cancelled
        let turn = Task { await store.sendCodexMessage("Synthetic turn", allowEdits: false, confirmed: false) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isCodexTurnRunning)
        await store.cancelCodexTurn()
        await fulfillment(of: [cancelled], timeout: 0.5)
        await turn.value
        XCTAssertFalse(store.isCodexTurnRunning)
        XCTAssertFalse(store.isCancellingCodex)
    }

    @MainActor
    func testLateInterviewKitDoesNotReopenClosedPackage() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "A")
        let started = expectation(description: "Kit started")
        let release = DispatchSemaphore(value: 0)
        service.kitStarted = started
        service.kitRelease = release
        let kit = Task { await store.prepareRealtimeInterviewKit() }
        await fulfillment(of: [started], timeout: 2)
        store.leavePackageDetailForSidebarNavigation()
        release.signal()
        await kit.value
        XCTAssertNil(store.selectedPackage)
        XCTAssertNil(store.interviewKitMessage)
    }

    func testMasterResumeSaveWithoutRubyFailsWithNamedToolMessageAndKeepsDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navcenter-ux-ruby-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try WorkspaceManager(workspaceRoot: root).initialize()
        let resume = root.appendingPathComponent("master-resumes/master_primary.yaml")
        let original = try Data(contentsOf: resume)
        let probe = ToolProbeConfiguration(
            environment: ["PATH": ""],
            homeDirectory: root,
            fallbackDirectories: [],
            isExecutableRegularFile: { _ in false }
        )
        let draft = "profile:\n  name: Synthetic unsaved draft\n"

        XCTAssertThrowsError(try MasterResumeStore(repoRoot: root, toolProbe: probe).save(content: draft)) { error in
            XCTAssertEqual(
                error as? NavCenterError,
                .invalidPath("Master resume save needs Ruby, which was not found on PATH. Reinstall Xcode Command Line Tools or use the Ruby included with macOS at /usr/bin/ruby.")
            )
        }

        XCTAssertEqual(try Data(contentsOf: resume), original)
        let work = root.appendingPathComponent("tmp/master-resume-editor")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("candidate-") })
        let backups = work.appendingPathComponent("backups")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [], [])
    }

    @MainActor
    func testMasterResumeRejectsExternalChangeAndKeepsDraft() async throws {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadMasterResume()
        store.masterResumeContent = "profile:\n  name: Synthetic unsaved draft\n"
        service.masterResumeOnDiskContent = "profile:\n  name: Synthetic external edit\n"

        let outcome = await store.saveMasterResume()

        guard case .notSaved = outcome else { return XCTFail("Expected the optimistic lock to reject the save") }
        XCTAssertTrue(service.savedMasterResumeContent.isEmpty)
        XCTAssertTrue(store.masterResumeContent.contains("Synthetic unsaved draft"))
        XCTAssertTrue(store.hasUnsavedMasterResume)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testNativeMasterResumeRejectsExternalChangeAndKeepsDraft() async throws {
        let root = try workspace()
        let store = DashboardStore(service: NativeDashboardService(repoRoot: root))
        await store.loadMasterResume()
        store.masterResumeContent = "profile:\n  name: Synthetic unsaved draft\n"
        let resume = root.appendingPathComponent("master-resumes/master_primary.yaml")
        let external = "profile:\n  name: Synthetic external edit\n"
        try external.write(to: resume, atomically: true, encoding: .utf8)

        let outcome = await store.saveMasterResume()

        guard case .notSaved = outcome else { return XCTFail("Expected the native optimistic lock to reject the save") }
        XCTAssertEqual(try String(contentsOf: resume), external)
        XCTAssertTrue(store.masterResumeContent.contains("Synthetic unsaved draft"))
        XCTAssertTrue(store.hasUnsavedMasterResume)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testMasterResumeSaveRefusesMissingSnapshotAndKeepsDraft() async {
        let service = UXTestService()
        let original = service.masterResumeOnDiskContent
        let store = DashboardStore(service: service)
        let draft = "profile:\n  name: Synthetic recovered draft\n"
        store.masterResumeContent = draft

        let outcome = await store.saveMasterResume()

        guard case .notSaved = outcome else { return XCTFail("Expected refusal before reviewing the saved resume") }
        XCTAssertTrue(service.savedMasterResumeContent.isEmpty)
        XCTAssertEqual(service.masterResumeOnDiskContent, original)
        XCTAssertEqual(store.masterResumeContent, draft)
        XCTAssertNil(store.masterResumeSnapshot)
        XCTAssertTrue(store.hasUnsavedMasterResume)
    }

    @MainActor
    func testNativeMasterResumeMissingSnapshotPreservesDiskAndDraft() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        let original = try service.loadMasterResume().content
        let store = DashboardStore(service: service)
        let draft = "profile:\n  name: Synthetic unseen draft\n"
        store.masterResumeContent = draft

        let outcome = await store.saveMasterResume()

        guard case .notSaved = outcome else { return XCTFail("Expected refusal without a reviewed snapshot") }
        XCTAssertEqual(try service.loadMasterResume().content, original)
        XCTAssertEqual(store.masterResumeContent, draft)
        XCTAssertNil(store.masterResumeSnapshot)
        XCTAssertTrue(store.hasUnsavedMasterResume)
    }

    @MainActor
    func testMasterResumeSaveWithSnapshotReturnsSavedOutcome() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        await store.loadMasterResume()
        let original = store.masterResumeContent
        store.masterResumeContent = "profile:\n  name: Synthetic saved draft\n"

        let outcome = await store.saveMasterResume()

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(service.savedMasterResumeExpectedContent, original)
        XCTAssertFalse(store.hasUnsavedMasterResume)
    }

    @MainActor
    func testMasterResumeLoadRecoveryDoesNotAuthorizeUnreviewedSave() async {
        let service = UXTestService()
        service.masterResumeLoadError = DashboardAPIError.serverUnavailable("Synthetic load failure")
        let store = DashboardStore(service: service)
        await store.loadMasterResume()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.masterResumeSnapshot)
        service.masterResumeLoadError = nil
        let original = service.masterResumeOnDiskContent
        let draft = "profile:\n  name: Synthetic retained draft\n"
        store.masterResumeContent = draft

        let outcome = await store.saveMasterResume()

        guard case .notSaved(let message) = outcome else { return XCTFail("Expected a failed save outcome") }
        XCTAssertTrue(message.contains("draft has been kept"))
        XCTAssertEqual(store.masterResumeContent, draft)
        XCTAssertTrue(store.hasUnsavedMasterResume)
        XCTAssertTrue(service.savedMasterResumeContent.isEmpty)
        XCTAssertEqual(service.masterResumeOnDiskContent, original)
        XCTAssertNil(store.masterResumeSnapshot)
    }

    @MainActor
    func testSlowSummaryDoesNotBlockMainQueue() async {
        let service = UXTestService()
        let started = expectation(description: "Slow background read")
        let heartbeat = expectation(description: "Main queue remains responsive")
        let release = DispatchSemaphore(value: 0)
        service.summaryStarted = started
        service.summaryRelease = release
        let store = DashboardStore(service: service)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.5)
        XCTAssertTrue(store.isLoading)
        release.signal()
        await refresh.value
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testMasterResumeReloadPreservesDraftUnlessExplicitlyDiscarded() async {
        let store = DashboardStore(service: UXTestService())
        await store.loadMasterResume()
        let saved = store.masterResumeContent
        store.masterResumeContent = "profile:\n  name: Synthetic unsaved draft\n"
        store.leavePackageDetailForSidebarNavigation()
        await store.loadMasterResume()
        XCTAssertTrue(store.masterResumeContent.contains("Synthetic unsaved draft"))
        XCTAssertTrue(store.hasUnsavedMasterResume)
        await store.loadMasterResume(discardUnsavedChanges: true)
        XCTAssertEqual(store.masterResumeContent, saved)
        XCTAssertFalse(store.hasUnsavedMasterResume)
    }

    @MainActor
    func testLateMasterResumeLoadCannotOverwriteNewTyping() async {
        let service = UXTestService()
        let started = expectation(description: "Load started")
        let release = DispatchSemaphore(value: 0)
        service.loadStarted = started
        service.loadRelease = release
        let store = DashboardStore(service: service)
        let load = Task { await store.loadMasterResume() }
        await fulfillment(of: [started], timeout: 2)
        store.masterResumeContent = "Synthetic typing after load started"
        release.signal()
        await load.value
        XCTAssertEqual(store.masterResumeContent, "Synthetic typing after load started")
    }

    @MainActor
    func testCorruptTrackerDegradesToPackagesAndRefusesTrackerWrites() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2020-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let preview = try service.previewPackageCleanup(olderThanDays: 7)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tracking", isDirectory: true), withIntermediateDirectories: false)
        let tracker = root.appendingPathComponent("tracking/applications.sqlite")
        let corruptBytes = Data("not a sqlite database".utf8)
        try corruptBytes.write(to: tracker)

        let summary = try service.fetchSummary()
        let response = try service.fetchApplications(limit: 10)
        let packageResponse = try service.fetchPackage(named: name)
        XCTAssertEqual(summary.totals.packages, 1)
        XCTAssertEqual(packageResponse.package.name, name)
        XCTAssertEqual(response.applications.map(\.packageName), [name])
        XCTAssertFalse(response.sources.tracker.available)
        XCTAssertEqual(response.sources.tracker.warnings.count, 1)
        XCTAssertTrue(response.sources.tracker.warnings[0].contains("Packages are still available"))
        let store = DashboardStore(service: service)
        try await store.refreshAll()
        XCTAssertTrue(store.dataWarningMessage?.contains("tracker could not be read") == true)

        XCTAssertThrowsError(try service.updatePackageStatus(packageName: name, status: .submitted)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Status changes are disabled"))
        }
        XCTAssertThrowsError(try service.applyPackageCleanup(olderThanDays: 7, deleteTracked: true, expectedPreview: preview)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Tracked cleanup"))
        }
        XCTAssertEqual(try Data(contentsOf: tracker), corruptBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("applications/" + name).path))
    }

    func testHealthyTrackerLoadsAndAcceptsStatusUpdatesWithoutWarning() throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)

        _ = try service.updatePackageStatus(packageName: name, status: .submitted)
        let response = try service.fetchApplications(limit: 10)
        XCTAssertTrue(response.sources.tracker.available)
        XCTAssertTrue(response.sources.tracker.warnings.isEmpty)
        XCTAssertEqual(response.applications.first?.status, "Submitted")

        let update = try service.updatePackageStatus(packageName: name, status: .interview)
        XCTAssertEqual(update.newStatus, "Interview")
    }

    func testMissingTrackerIsNormalPackageOnlyViewWithoutWarning() throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)

        let response = try service.fetchApplications(limit: 10)

        XCTAssertFalse(response.sources.tracker.available)
        XCTAssertTrue(response.sources.tracker.warnings.isEmpty)
        XCTAssertEqual(response.applications.map(\.packageName), [name])
        XCTAssertEqual(response.applications.first?.source.package, true)
        XCTAssertEqual(response.applications.first?.source.tracker, false)
    }

    func testUnreadableTrackerDirectoryDegradesToPackagesAndRefusesWrites() throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let tracking = root.appendingPathComponent("tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: tracking, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(tracking.path, 0), 0)
        defer { _ = chmod(tracking.path, 0o700) }

        let response = try service.fetchApplications(limit: 10)

        XCTAssertEqual(response.applications.map(\.packageName), [name])
        XCTAssertFalse(response.sources.tracker.available)
        XCTAssertEqual(response.sources.tracker.warnings, ["The tracker could not be read. Packages are still available, but status changes and tracked cleanup are disabled until the tracker is accessible and valid."])
        XCTAssertThrowsError(try service.updatePackageStatus(packageName: name, status: .submitted)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Status changes are disabled"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracking.appendingPathComponent("applications.sqlite").path))
    }

    func testSymlinkedTrackerDirectoryStillFailsPackageLoading() throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let tracking = root.appendingPathComponent("tracking", isDirectory: true)
        let outside = root.appendingPathComponent("outside-tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: tracking, withDestinationURL: outside)

        XCTAssertThrowsError(try service.fetchApplications(limit: 10)) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"))
        }
    }

    func testAbsentTrackerDirectoryHasNoWarningAndFirstStatusCreatesIt() throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let tracking = root.appendingPathComponent("tracking", isDirectory: true)

        let response = try service.fetchApplications(limit: 10)

        XCTAssertEqual(response.applications.map(\.packageName), [name])
        XCTAssertFalse(response.sources.tracker.available)
        XCTAssertTrue(response.sources.tracker.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tracking.path))
        _ = try service.updatePackageStatus(packageName: name, status: .submitted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracking.appendingPathComponent("applications.sqlite").path))
        XCTAssertTrue(try service.fetchApplications(limit: 10).sources.tracker.available)
    }

    @MainActor
    func testAll501ApplicationsAreLoaded() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        for index in 0...500 { try package("2099-01-01_Synthetic_\(index)", in: root) }
        let store = DashboardStore(service: service)
        try await store.refreshAll()
        XCTAssertEqual(store.applications.count, 501)
        XCTAssertEqual(store.summary?.totals.applications, 501)
        XCTAssertTrue(store.applications.contains { $0.packageName == "2099-01-01_Synthetic_500" })
    }

    @MainActor
    func testRefreshInvalidatesPreviewAndPackageInventory() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let store = DashboardStore(service: service)
        await store.loadPackage(named: name)
        let posting = try XCTUnwrap(store.selectedPackage?.package.files.first { $0.relativePath == "posting.md" })
        await store.loadFilePreview(posting)
        let folder = root.appendingPathComponent("applications/" + name)
        try "# Updated synthetic posting\n".write(to: folder.appendingPathComponent("posting.md"), atomically: true, encoding: .utf8)
        try "# Synthetic resume\n".write(to: folder.appendingPathComponent("Resume_" + name + ".md"), atomically: true, encoding: .utf8)
        await store.refresh()
        XCTAssertTrue(store.filePreview(for: posting)?.content.contains("Updated synthetic") == true)
        XCTAssertEqual(store.selectedPackage?.package.files.count, 2)
    }

    @MainActor
    func testArtifactURLRejectsMissingAndLinkedFiles() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2099-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let folder = root.appendingPathComponent("applications/" + name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("artifacts"), withIntermediateDirectories: false)
        let binary = folder.appendingPathComponent("artifacts/document.docx")
        try Data("Synthetic binary".utf8).write(to: binary)
        let store = DashboardStore(service: service)
        await store.loadPackage(named: name)
        let file = try XCTUnwrap(store.selectedPackage?.package.files.first { $0.relativePath == "artifacts/document.docx" })
        XCTAssertEqual(try store.validatedFileURL(for: file).standardizedFileURL, binary.standardizedFileURL)
        try FileManager.default.removeItem(at: binary)
        XCTAssertThrowsError(try store.validatedFileURL(for: file))
        let outside = root.appendingPathComponent("synthetic-outside.docx")
        try Data("Outside sentinel".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: outside)
        XCTAssertThrowsError(try store.validatedFileURL(for: file))
    }

    @MainActor
    func testCleanupWithoutPreviewIsRefusedWithPreviewFirstMessage() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)

        await store.applyPackageCleanup()

        XCTAssertEqual(store.errorMessage, "Preview the packages before confirming cleanup.")
        XCTAssertEqual(service.cleanupApplyCallCount, 0)
    }

    @MainActor
    func testCleanupWithDifferentAgeThresholdIsRefusedAsStale() async {
        let service = UXTestService()
        let store = DashboardStore(service: service)
        store.cleanupPreview = service.cleanupPreview(olderThanDays: 30)

        await store.applyPackageCleanup(olderThanDays: 7)

        XCTAssertTrue(store.errorMessage?.contains("stale") == true)
        XCTAssertFalse(store.errorMessage?.contains("Preview the packages before confirming cleanup.") == true)
        XCTAssertEqual(service.cleanupApplyCallCount, 0)
    }

    @MainActor
    func testCleanupAlreadyRunningDoesNotStartAgainOrRequestPreview() async {
        let service = UXTestService()
        let started = expectation(description: "Cleanup started")
        let release = DispatchSemaphore(value: 0)
        service.cleanupApplyStarted = started
        service.cleanupApplyRelease = release
        let store = DashboardStore(service: service)
        let preview = service.cleanupPreview(olderThanDays: 7)
        store.cleanupPreview = preview

        let firstCleanup = Task { await store.applyPackageCleanup(confirmedPreview: preview) }
        await fulfillment(of: [started], timeout: 2)
        await store.applyPackageCleanup(confirmedPreview: preview)

        XCTAssertEqual(service.cleanupApplyCallCount, 1)
        XCTAssertEqual(store.cleanupMessage, "Package cleanup is already running.")
        XCTAssertFalse(store.errorMessage?.contains("Preview") == true)

        release.signal()
        await firstCleanup.value
    }

    @MainActor
    func testSuccessfulCleanupReportsResultRetainsRefreshedPreviewAndRefreshesDashboard() async {
        let service = UXTestService()
        service.cleanupWarnings = ["Synthetic cleanup warning."]
        let store = DashboardStore(service: service)
        let preview = service.cleanupPreview(olderThanDays: 7)
        service.cleanupPreviewAfterApply = service.cleanupPreview(olderThanDays: 7, packageName: "2020-01-02_Remaining_Engineer")
        store.cleanupPreview = preview

        await store.applyPackageCleanup(confirmedPreview: preview)

        XCTAssertEqual(service.cleanupApplyCallCount, 1)
        XCTAssertEqual(service.cleanupPreviewCallCount, 1)
        XCTAssertEqual(service.summaryCallCount, 1)
        XCTAssertEqual(service.applicationsCallCount, 1)
        XCTAssertEqual(store.cleanupPreview, service.cleanupPreviewAfterApply)
        XCTAssertTrue(store.cleanupMessage?.contains("Removed 1 package.") == true)
        XCTAssertTrue(store.cleanupMessage?.contains("Backup: cleanup-backup") == true)
        XCTAssertTrue(store.cleanupMessage?.contains("Synthetic cleanup warning.") == true)
        XCTAssertNotNil(store.summary)
    }

    @MainActor
    func testCleanupRequiresDisplayedPreviewAndRejectsChangedPackage() async throws {
        let root = try workspace()
        let service = NativeDashboardService(repoRoot: root)
        _ = try service.fetchSummary()
        let name = "2020-01-01_Synthetic_Engineer"
        try package(name, in: root)
        let folder = root.appendingPathComponent("applications/" + name)
        let store = DashboardStore(service: service)
        await store.applyPackageCleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.errorMessage?.contains("Preview") == true)
        await store.previewPackageCleanup()
        let preview = try XCTUnwrap(store.cleanupPreview)
        XCTAssertEqual(preview.candidates.count, 1)
        try "# Changed after confirmation preview\n".write(to: folder.appendingPathComponent("posting.md"), atomically: true, encoding: .utf8)
        await store.applyPackageCleanup(confirmedPreview: preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(store.cleanupPreview)
        XCTAssertTrue(store.errorMessage?.contains("changed") == true)
        await store.previewPackageCleanup()
        await store.applyPackageCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(store.cleanupPreview)
        XCTAssertEqual(store.summary?.totals.packages, 0)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nav-center-ux-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func package(_ name: String, in root: URL) throws {
        let folder = root.appendingPathComponent("applications/" + name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "# Synthetic posting\n".write(to: folder.appendingPathComponent("posting.md"), atomically: true, encoding: .utf8)
    }
}

private final class UXTestService: DashboardServicing, @unchecked Sendable {
    let repoRoot = URL(fileURLWithPath: "/tmp/nav-center-intake-test")
    var createdRequests: [JobDescriptionIntakeRequest] = []
    var savedMasterResumeContent = ""
    var savedMasterResumeExpectedContent: String?
    var masterResumeOnDiskContent = "profile:\n  name: Example Candidate\n"
    var masterResumeLoadError: Error?
    var cleanupApplyStarted: XCTestExpectation?
    var cleanupApplyRelease: DispatchSemaphore?
    var cleanupWarnings: [String] = []
    var cleanupPreviewAfterApply: PackageCleanupPreview?
    private(set) var cleanupPreviewCallCount = 0
    private(set) var cleanupApplyCallCount = 0
    private(set) var summaryCallCount = 0
    private(set) var applicationsCallCount = 0
    private let requestLock = NSLock()
    private var recordedRequests: [CodexChatRequest] = []
    var sentCodexRequests: [CodexChatRequest] { requestLock.lock(); defer { requestLock.unlock() }; return recordedRequests }
    var chatStarted: XCTestExpectation?
    var chatRelease: DispatchSemaphore?
    var chatError: Error?
    var summaryStarted: XCTestExpectation?
    var summaryRelease: DispatchSemaphore?
    var loadStarted: XCTestExpectation?
    var loadRelease: DispatchSemaphore?
    var kitStarted: XCTestExpectation?
    var kitRelease: DispatchSemaphore?
    var cancelled: XCTestExpectation?

    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult {
        createdRequests.append(request)
        return CreateApplicationResult(
            packageName: "2099-04-01_Paste_Corp_Product_Security_Engineer",
            packageURL: repoRoot.appendingPathComponent("applications/2099-04-01_Paste_Corp_Product_Security_Engineer"),
            postingURL: repoRoot.appendingPathComponent("applications/2099-04-01_Paste_Corp_Product_Security_Engineer/posting.md"),
            dryRun: false
        )
    }

    func loadMasterResume() throws -> MasterResumeSnapshot {
        loadStarted?.fulfill()
        if let loadRelease { _ = loadRelease.wait(timeout: .now() + 5) }
        if let masterResumeLoadError { throw masterResumeLoadError }
        return MasterResumeSnapshot(
            relativePath: "master-resumes/master_primary.yaml",
            content: masterResumeOnDiskContent,
            modifiedAt: "2099-04-01T12:00:00Z"
        )
    }

    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult {
        savedMasterResumeExpectedContent = expectedContent
        guard expectedContent == masterResumeOnDiskContent else {
            throw DashboardAPIError.serverUnavailable("Master resume changed on disk. Reload and reconcile your draft before saving.")
        }
        savedMasterResumeContent = content
        masterResumeOnDiskContent = content
        return MasterResumeSaveResult(
            relativePath: "master-resumes/master_primary.yaml",
            savedURL: repoRoot.appendingPathComponent("master-resumes/master_primary.yaml"),
            backupURL: repoRoot.appendingPathComponent("tmp/master-resume-editor/backups/master_primary.yaml"),
            modifiedAt: "2099-04-01T12:05:00Z"
        )
    }

    func fetchSummary() throws -> DashboardSummary {
        summaryCallCount += 1
        summaryStarted?.fulfill()
        if let summaryRelease { _ = summaryRelease.wait(timeout: .now() + 5) }
        return DashboardSummary(
            generatedAt: "2099-04-01T12:00:00Z",
            localOnly: true,
            totals: DashboardTotals(
                applications: 1,
                trackerRows: 0,
                packageOnly: 1,
                packages: 1,
                artifacts: 0,
                nextActionsDue: 0,
                pursueNow: 1,
                generated: 0,
                submitted: 0,
                interviews: 0
            ),
            statusCounts: [:],
            upcomingActions: [],
            recentApplications: [],
            packageHealth: PackageHealthSummary(
                withPosting: 1,
                withResumeSource: 0,
                withInterviewPrep: 0,
                withArtifacts: 0,
                withAtsFiles: 0
            ),
            sources: Self.sources()
        )
    }

    func fetchApplications(limit: Int) throws -> ApplicationsResponse {
        applicationsCallCount += 1
        return ApplicationsResponse(
            generatedAt: "2099-04-01T12:00:00Z",
            total: 1,
            limit: limit,
            offset: 0,
            applications: [],
            sources: Self.sources()
        )
    }

    func fetchPackage(named packageName: String) throws -> PackageResponse {
        PackageResponse(
            generatedAt: "2099-04-01T12:00:00Z",
            package: ApplicationPackage(
                name: packageName,
                applicationDir: "applications/\(packageName)",
                metadata: ["company": .string("Paste Corp"), "role": .string("Product Security Engineer")],
                files: [PackageFile(relativePath: "interview-transcript.md", label: "Transcript", kind: "interview", format: "md", size: 20, modifiedAt: "", previewable: true, previewUrl: nil, rawUrl: nil, editable: true)],
                tabs: [
                    PackageTab(key: PackageTabKey.posting.rawValue, label: "Posting", available: true, fileCount: 0, primaryFile: nil, files: [])
                ],
                artifactSummary: ArtifactSummary(total: 0, previewable: 0, ats: 0, byFormat: [:], byKind: [:]),
                health: PackageHealth.empty
            ),
            application: nil,
            statusEvents: [],
            sources: Self.sources()
        )
    }

    func fetchTab(packageName: String, tabKey: String, file: String?) throws -> PackageTabPreviewResponse {
        PackageTabPreviewResponse(
            packageName: packageName,
            tab: PackageTab(key: tabKey, label: "Posting", available: true, fileCount: 0, primaryFile: nil, files: []),
            file: nil,
            content: nil
        )
    }

    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse {
        ActionLogResponse(generatedAt: "2099-04-01T12:00:00Z", localOnly: true, actions: [])
    }

    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview {
        cleanupPreviewCallCount += 1
        return cleanupPreviewAfterApply ?? cleanupPreview(olderThanDays: olderThanDays)
    }

    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult {
        cleanupApplyCallCount += 1
        cleanupApplyStarted?.fulfill()
        if let cleanupApplyRelease { _ = cleanupApplyRelease.wait(timeout: .now() + 5) }
        return PackageCleanupResult(
            preview: expectedPreview,
            removedPackages: expectedPreview.candidates,
            backupURL: repoRoot.appendingPathComponent("tmp/package-cleanup/cleanup-backup"),
            manifestURL: repoRoot.appendingPathComponent("tmp/package-cleanup/cleanup-backup/manifest.json"),
            warnings: cleanupWarnings
        )
    }

    func cleanupPreview(olderThanDays: Int, packageName: String = "2020-01-01_Synthetic_Engineer") -> PackageCleanupPreview {
        let candidate = PackageCleanupCandidate(
            packageName: packageName,
            packageDate: "2020-01-01",
            applicationDir: "applications/\(packageName)",
            trackerID: nil,
            status: "Package Only",
            isTracked: false
        )
        return PackageCleanupPreview(
            today: "2099-04-01",
            cutoffDate: "2099-03-25",
            olderThanDays: olderThanDays,
            candidates: [candidate],
            fingerprint: "synthetic-fingerprint-\(olderThanDays)"
        )
    }

    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse {
        kitStarted?.fulfill()
        if let kitRelease { _ = kitRelease.wait(timeout: .now() + 5) }
        return RealtimeInterviewKitResponse(ok: true, packageName: packageName, generatedAt: "2099-01-01", outputPaths: ["realtime-interview-session.json"], sessionConfigPath: "realtime-interview-session.json", transcriptPath: "interview-transcript.md", reviewPromptPath: "interview-review-prompt.md", wroteFiles: true)
    }

    func realtimeInterviewReviewPrompt(packageName: String) throws -> String { "Review " + packageName }

    func localFileURL(packageName: String, relativePath: String) throws -> URL {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchCodexStatus() throws -> CodexStatusResponse {
        CodexStatusResponse(
            ok: true,
            userAgent: "Codex Desktop/fixture",
            codexHome: "/tmp/codex-home",
            account: CodexAccount(type: "chatgpt", email: "tester@example.com", planType: "pro"),
            requiresOpenaiAuth: false,
            authMethod: "chatgpt",
            localOnly: true
        )
    }

    func startCodexLogin(type: String) throws -> CodexLoginStartResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse {
        requestLock.lock()
        recordedRequests.append(payload)
        requestLock.unlock()
        chatStarted?.fulfill()
        if let chatRelease { _ = chatRelease.wait(timeout: .now() + 5) }
        if let chatError { throw chatError }
        return CodexChatResponse(
            ok: true,
            threadId: payload.threadId ?? "thread_" + payload.packageName,
            turnId: "turn_\(sentCodexRequests.count)",
            status: "completed",
            message: "Response \(sentCodexRequests.count)",
            diff: "",
            account: CodexAccount(type: "chatgpt", email: "tester@example.com", planType: "pro")
        )
    }

    func cancelCodexTurn() throws {
        cancelled?.fulfill()
        chatRelease?.signal()
    }

    private static func sources() -> DashboardSources {
        DashboardSources(
            tracker: TrackerSource(available: true, driver: "fixture", readOnly: false, queryOnly: false, warnings: []),
            packages: PackageSource(available: true, scanned: 1, warnings: [])
        )
    }
}
