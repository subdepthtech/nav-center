import XCTest
import struct NavCenterCore.CreateApplicationResult
import struct NavCenterCore.MasterResumeSaveResult
import struct NavCenterCore.MasterResumeSnapshot
import enum NavCenterCore.TrackerStatus
import struct NavCenterCore.TrackerStatusUpdateResult
import struct NavCenterCore.PackageCleanupCandidate
import struct NavCenterCore.PackageCleanupPreview
import struct NavCenterCore.PackageCleanupResult
import struct NavCenterCore.ImportedDocument
@testable import NavCenterApp

final class DashboardParityTests: XCTestCase {
    func testNavigationMatchesWebDashboardSections() {
        XCTAssertEqual(
            DashboardDestination.allCases.map(\.rawValue),
            ["overview", "applications", "packages", "searches", "resume", "exports", "settings"]
        )
        XCTAssertEqual(
            DashboardDestination.allCases.map(\.title),
            ["Overview", "Applications", "Packages", "Job Searches", "Master Resume", "Exports", "Settings"]
        )
    }

    func testPackageActionRailMatchesWebQuickActions() {
        let actions = PackageAction.railActions

        XCTAssertEqual(actions.map(\.title), ["Run ATS Scan", "Export Artifacts", "Sync to Vault"])
        XCTAssertEqual(actions.map(\.isEnabled), [true, false, false])
        XCTAssertEqual(actions.first?.confirmationTitle, "Confirm ATS Scan")
        XCTAssertEqual(
            actions.first?.message,
            "Runs a local package scan and refreshes the package ATS report."
        )
        XCTAssertEqual(
            actions.first?.commandPreview(packageName: "2026-05-05_Example_Security_Engineer"),
            "atsim scan applications/2026-05-05_Example_Security_Engineer --out applications/2026-05-05_Example_Security_Engineer/artifacts/ats-report.json"
        )
    }

    func testTrackerStatusQuickActionsMatchDashboardButtons() {
        let actions = TrackerStatusQuickAction.allCases

        XCTAssertEqual(actions.map(\.title), ["Applied", "Interview", "Skip"])
        XCTAssertEqual(actions.map(\.help), ["Mark applied", "Mark interview", "Mark not pursuing"])
        XCTAssertEqual(actions.map(\.systemImage), ["paperplane", "person.2", "xmark.circle"])
        XCTAssertEqual(actions.map { $0.trackerStatus.rawValue }, ["Submitted", "Interview", "Not Pursuing"])
    }

    func testCodexChatMessagesUseRealAppServerRoles() {
        let messages = [
            CodexChatMessage(role: .user, text: "Review the package"),
            CodexChatMessage(role: .assistant, text: "Use the ATS tab first"),
            CodexChatMessage(role: .system, text: "Sign in required")
        ]

        XCTAssertEqual(messages.map(\.role.rawValue), ["user", "assistant", "system"])
        XCTAssertEqual(messages.map(\.text).last, "Sign in required")
    }

    @MainActor
    func testSidebarNavigationLeavesOpenPackageDetail() {
        let store = DashboardStore()
        let tab = PackageTab(
            key: PackageTabKey.interviewPrep.rawValue,
            label: "Interview Prep",
            available: true,
            fileCount: 0,
            primaryFile: nil,
            files: []
        )
        store.selectedPackage = PackageResponse(
            generatedAt: "2026-05-13T12:00:00.000Z",
            package: ApplicationPackage(
                name: "2026-05-13_Example_Security_Engineer",
                applicationDir: "applications/2026-05-13_Example_Security_Engineer",
                metadata: [:],
                files: [],
                tabs: [tab],
                artifactSummary: ArtifactSummary(total: 0, previewable: 0, ats: 0, byFormat: [:], byKind: [:]),
                health: PackageHealth.empty
            ),
            application: nil,
            statusEvents: [],
            sources: dashboardSources()
        )
        store.selectedTabPreview = PackageTabPreviewResponse(
            packageName: "2026-05-13_Example_Security_Engineer",
            tab: tab,
            file: nil,
            content: "Preview"
        )
        store.activePackageTabKey = PackageTabKey.interviewPrep.rawValue

        store.leavePackageDetailForSidebarNavigation()

        XCTAssertNil(store.selectedPackage)
        XCTAssertNil(store.selectedTabPreview)
        XCTAssertEqual(store.activePackageTabKey, PackageTabKey.review.rawValue)
    }

    @MainActor
    func testStoreCreatesPackageFromPastedPostingAndOpensItWithoutCodex() async {
        let service = IntakeDashboardService()
        let store = DashboardStore(service: service)
        let request = JobDescriptionIntakeRequest(
            company: "Paste Corp",
            role: "Product Security Engineer",
            postingText: "Responsibilities include required experience with security architecture, compliance, leadership, preferred cloud security, and incident response.",
            sourceURL: "https://example.com/job",
            location: "Remote",
            salary: "$170k-$210k"
        )

        await store.createPackageFromIntake(request, runCodexAutomation: false)

        XCTAssertEqual(service.createdRequests.map(\.company), ["Paste Corp"])
        XCTAssertEqual(store.selectedPackage?.package.name, "2099-04-01_Paste_Corp_Product_Security_Engineer")
        XCTAssertEqual(store.intakeMessage, "Created package: 2099-04-01_Paste_Corp_Product_Security_Engineer")
        XCTAssertTrue(store.codexMessages.isEmpty)
    }

    @MainActor
    func testStoreSendsSecondCodexMessageOnExistingThread() async {
        let service = IntakeDashboardService()
        let store = DashboardStore(service: service)
        store.selectedPackage = try? service.fetchPackage(named: "2099-04-01_Paste_Corp_Product_Security_Engineer")

        await store.sendCodexMessage("Review the package.", allowEdits: false, confirmed: false)
        await store.sendCodexMessage("Now draft interview prep.", allowEdits: true, confirmed: true)

        XCTAssertEqual(service.sentCodexRequests.map(\.message), ["Review the package.", "Now draft interview prep."])
        XCTAssertEqual(service.sentCodexRequests.map(\.threadId), [nil, "thread_1"])
        XCTAssertEqual(store.codexThreadId, "thread_1")
        XCTAssertEqual(store.codexMessages.map(\.role.rawValue), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(store.codexErrorMessage, nil)
    }

    @MainActor
    func testStoreLoadsAndSavesMasterResumeContent() async {
        let service = IntakeDashboardService()
        let store = DashboardStore(service: service)

        await store.loadMasterResume()
        XCTAssertEqual(store.masterResumeContent, "profile:\n  name: Example Candidate\n")

        store.masterResumeContent = "profile:\n  name: Example Candidate\nsummary:\n  - Product security\n"
        await store.saveMasterResume()

        XCTAssertEqual(service.savedMasterResumeContent, store.masterResumeContent)
        XCTAssertEqual(store.masterResumeMessage, "Saved master-resumes/master_primary.yaml")
    }

    @MainActor
    func testCleanupActionRefreshesSummaryAfterPreviewInvalidatesStalePackageScan() async {
        let service = CleanupRefreshService()
        let store = DashboardStore(service: service)

        try? await store.refreshAll()
        XCTAssertEqual(store.summary?.totals.packages, 59)

        await store.applyPackageCleanup(olderThanDays: 7, deleteTracked: true)

        XCTAssertEqual(store.cleanupPreview?.candidates.count, 0)
        XCTAssertEqual(store.summary?.totals.packages, 16)
        XCTAssertEqual(store.summary?.packageHealth.withPosting, 9)
        XCTAssertEqual(service.events, ["apply", "preview", "summary", "applications"])
    }

    func testPackageHealthRailMatchesWebChecklist() {
        let package = ApplicationPackage(
            name: "2026-05-05_Example_Security_Engineer",
            applicationDir: "applications/2026-05-05_Example_Security_Engineer",
            metadata: [:],
            files: [
                packageFile("posting.md", kind: "posting", format: "md"),
                packageFile("Resume_2026-05-05_Example_Security_Engineer.md", kind: "resume-source", format: "md"),
                packageFile("artifacts/Resume_2026-05-05_Example_Security_Engineer.pdf", kind: "artifact", format: "pdf"),
                packageFile("artifacts/Resume_2026-05-05_Example_Security_Engineer.docx", kind: "artifact", format: "docx"),
                packageFile("artifacts/Resume_2026-05-05_Example_Security_Engineer.pdf.txt", kind: "artifact", format: "txt"),
                packageFile("artifacts/ats-report.json", kind: "ats-artifact", format: "json")
            ],
            tabs: [],
            artifactSummary: ArtifactSummary(total: 4, previewable: 2, ats: 1, byFormat: [:], byKind: [:]),
            health: PackageHealth(
                hasPosting: true,
                hasResumeSource: true,
                hasCoverLetterSource: false,
                hasInterviewPrep: false,
                artifactCount: 4,
                atsFileCount: 1,
                hasAtsReport: true,
                hasAtsJson: true,
                previewableCount: 3
            )
        )

        let checks = PackageHealthCheck.items(for: package)

        XCTAssertEqual(
            checks.map(\.label),
            [
                "Posting captured",
                "Resume drafted",
                "PDF generated",
                "DOCX generated",
                "Extraction OK",
                "ATS available",
                "Interview prep"
            ]
        )
        XCTAssertEqual(checks.map(\.isPassing), [true, true, true, true, true, true, false])
    }

    private func packageFile(
        _ relativePath: String,
        kind: String,
        format: String,
        rawUrl: String? = nil,
        modifiedAt: String = "2026-05-06T13:00:00.000Z"
    ) -> PackageFile {
        PackageFile(
            relativePath: relativePath,
            label: relativePath.split(separator: "/").last.map(String.init) ?? relativePath,
            kind: kind,
            format: format,
            size: 128,
            modifiedAt: modifiedAt,
            previewable: ["md", "txt", "json", "html"].contains(format),
            previewUrl: nil,
            rawUrl: rawUrl,
            editable: false
        )
    }

    private func dashboardSources() -> DashboardSources {
        DashboardSources(
            tracker: TrackerSource(available: true, driver: "fixture", readOnly: true, queryOnly: true, warnings: []),
            packages: PackageSource(available: true, scanned: 1, warnings: [])
        )
    }
}

private final class IntakeDashboardService: DashboardServicing {
    let repoRoot = URL(fileURLWithPath: "/tmp/nav-center-intake-test")
    var createdRequests: [JobDescriptionIntakeRequest] = []
    var savedMasterResumeContent = ""
    var sentCodexRequests: [CodexChatRequest] = []

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
        MasterResumeSnapshot(
            relativePath: "master-resumes/master_primary.yaml",
            content: "profile:\n  name: Example Candidate\n",
            modifiedAt: "2099-04-01T12:00:00Z"
        )
    }

    func saveMasterResume(content: String) throws -> MasterResumeSaveResult {
        savedMasterResumeContent = content
        return MasterResumeSaveResult(
            relativePath: "master-resumes/master_primary.yaml",
            savedURL: repoRoot.appendingPathComponent("master-resumes/master_primary.yaml"),
            backupURL: repoRoot.appendingPathComponent("tmp/master-resume-editor/backups/master_primary.yaml"),
            modifiedAt: "2099-04-01T12:05:00Z"
        )
    }

    func fetchSummary() throws -> DashboardSummary {
        DashboardSummary(
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
        ApplicationsResponse(
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
                files: [],
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
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool) throws -> PackageCleanupResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func realtimeInterviewReviewPrompt(packageName: String) throws -> String {
        throw DashboardAPIError.serverUnavailable("not used")
    }

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
        sentCodexRequests.append(payload)
        return CodexChatResponse(
            ok: true,
            threadId: payload.threadId ?? "thread_1",
            turnId: "turn_\(sentCodexRequests.count)",
            status: "completed",
            message: "Response \(sentCodexRequests.count)",
            diff: "",
            account: CodexAccount(type: "chatgpt", email: "tester@example.com", planType: "pro")
        )
    }

    private static func sources() -> DashboardSources {
        DashboardSources(
            tracker: TrackerSource(available: true, driver: "fixture", readOnly: false, queryOnly: false, warnings: []),
            packages: PackageSource(available: true, scanned: 1, warnings: [])
        )
    }
}

private final class CleanupRefreshService: DashboardServicing {
    let repoRoot = URL(fileURLWithPath: "/tmp/nav-center-test")
    var events: [String] = []
    private var cleanupApplied = false
    private var previewedAfterApply = false

    func fetchSummary() throws -> DashboardSummary {
        events.append("summary")
        return previewedAfterApply ? Self.summary(packages: 16, withPosting: 9) : Self.summary(packages: 59, withPosting: 52)
    }

    func fetchApplications(limit: Int) throws -> ApplicationsResponse {
        events.append("applications")
        return ApplicationsResponse(
            generatedAt: "2026-05-13T12:00:00Z",
            total: previewedAfterApply ? 16 : 59,
            limit: limit,
            offset: 0,
            applications: [],
            sources: Self.sources()
        )
    }

    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview {
        events.append("preview")
        if cleanupApplied {
            previewedAfterApply = true
        }
        return PackageCleanupPreview(
            today: "2026-05-13",
            cutoffDate: "2026-05-06",
            olderThanDays: olderThanDays,
            candidates: []
        )
    }

    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool) throws -> PackageCleanupResult {
        events.removeAll()
        events.append("apply")
        cleanupApplied = true
        let preview = PackageCleanupPreview(
            today: "2026-05-13",
            cutoffDate: "2026-05-06",
            olderThanDays: olderThanDays,
            candidates: [
                PackageCleanupCandidate(
                    packageName: "2026-04-10_Old_Package",
                    packageDate: "2026-04-10",
                    applicationDir: "applications/2026-04-10_Old_Package",
                    trackerID: nil,
                    status: "Package Only",
                    isTracked: false
                )
            ]
        )
        return PackageCleanupResult(
            preview: preview,
            removedPackages: preview.candidates,
            backupURL: repoRoot.appendingPathComponent("tmp/package-cleanup/test/applications.sqlite.backup"),
            manifestURL: repoRoot.appendingPathComponent("tmp/package-cleanup/test/manifest.json")
        )
    }

    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func loadMasterResume() throws -> MasterResumeSnapshot {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func saveMasterResume(content: String) throws -> MasterResumeSaveResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchPackage(named packageName: String) throws -> PackageResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchTab(packageName: String, tabKey: String, file: String?) throws -> PackageTabPreviewResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse {
        ActionLogResponse(generatedAt: "2026-05-13T12:00:00Z", localOnly: true, actions: [])
    }

    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func realtimeInterviewReviewPrompt(packageName: String) throws -> String {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func localFileURL(packageName: String, relativePath: String) throws -> URL {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchCodexStatus() throws -> CodexStatusResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func startCodexLogin(type: String) throws -> CodexLoginStartResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    private static func summary(packages: Int, withPosting: Int) -> DashboardSummary {
        DashboardSummary(
            generatedAt: "2026-05-13T12:00:00Z",
            localOnly: true,
            totals: DashboardTotals(
                applications: packages,
                trackerRows: 0,
                packageOnly: packages,
                packages: packages,
                artifacts: packages,
                nextActionsDue: 0,
                pursueNow: 0,
                generated: 0,
                submitted: 0,
                interviews: 0
            ),
            statusCounts: [:],
            upcomingActions: [],
            recentApplications: [],
            packageHealth: PackageHealthSummary(
                withPosting: withPosting,
                withResumeSource: withPosting,
                withInterviewPrep: 0,
                withArtifacts: packages,
                withAtsFiles: packages == 16 ? 2 : 10
            ),
            sources: sources()
        )
    }

    private static func sources() -> DashboardSources {
        DashboardSources(
            tracker: TrackerSource(available: true, driver: "fixture", readOnly: false, queryOnly: false, warnings: []),
            packages: PackageSource(available: true, scanned: 1, warnings: [])
        )
    }
}
