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
import struct NavCenterCore.ToolAvailabilityReport
import struct NavCenterCore.ToolStatus
import enum NavCenterCore.ExternalTool
import enum NavCenterCore.ToolState
import class NavCenterCore.FeedbackDiagnostics
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
        XCTAssertEqual(actions.map { $0.availability(nil).enabled }, [true, true, false])
        XCTAssertEqual(actions.map { $0.availability(.empty).enabled }, [true, true, false])
        XCTAssertEqual(actions.first?.confirmationTitle, "Confirm ATS Scan")
        XCTAssertEqual(
            actions.first?.message(tools: nil),
            "Runs a local package scan and refreshes the package ATS report."
        )
        XCTAssertEqual(
            actions.first?.commandPreview(packageName: "2026-05-05_Example_Security_Engineer", tools: nil),
            "atsim scan applications/2026-05-05_Example_Security_Engineer --out applications/2026-05-05_Example_Security_Engineer/artifacts/ats-report.json"
        )
        XCTAssertEqual(actions[1].confirmationTitle, "Confirm Export")
        XCTAssertEqual(
            actions[1].message(tools: nil),
            "Exports this package's resume to HTML, DOCX, PDF, and text extractions in artifacts/ using Pandoc, Google Chrome, and pdftotext. Vault sync is skipped."
        )
        XCTAssertEqual(
            actions[1].commandPreview(packageName: "2026-05-05_Example_Security_Engineer", tools: .empty),
            "NAV_CENTER_SKIP_VAULT_SYNC=1 native-export export applications/2026-05-05_Example_Security_Engineer/Resume_2026-05-05_Example_Security_Engineer.md"
        )
        XCTAssertEqual(actions[2].message(tools: nil), "Reserved for a later confirmed vault sync workflow.")
        XCTAssertNil(actions[2].commandPreview(packageName: "2026-05-05_Example_Security_Engineer", tools: nil))

        let external = ToolAvailabilityReport(tools: [toolStatus(.exportTool, .found)])
        XCTAssertEqual(
            actions[1].message(tools: external),
            "Runs the exporter set in NAV_CENTER_EXPORT_BIN on this package's resume. Nav Center validates the refreshed PDF; the exporter must honor NAV_CENTER_SKIP_VAULT_SYNC=1."
        )
        XCTAssertEqual(
            actions[1].commandPreview(packageName: "2026-05-05_Example_Security_Engineer", tools: external),
            "NAV_CENTER_SKIP_VAULT_SYNC=1 $NAV_CENTER_EXPORT_BIN export applications/2026-05-05_Example_Security_Engineer/Resume_2026-05-05_Example_Security_Engineer.md"
        )
    }

    func testExportRailIsDisabledWithReasonWhenExportToolsMissing() {
        let missingChrome = ToolAvailabilityReport(tools: [
            toolStatus(.exportTool, .builtIn),
            toolStatus(.pandoc, .found),
            toolStatus(.pdftotext, .found),
            toolStatus(.chrome, .missing)
        ])
        let missing = PackageAction.exportArtifacts.availability(missingChrome)
        XCTAssertFalse(missing.enabled)
        XCTAssertEqual(missing.reason, "Export needs Pandoc, pdftotext, and Google Chrome. See Settings > External Tools.")

        for absent in [ExternalTool.pandoc, .pdftotext] {
            let report = ToolAvailabilityReport(tools: [
                toolStatus(.exportTool, .builtIn),
                toolStatus(.pandoc, absent == .pandoc ? .missing : .found),
                toolStatus(.pdftotext, absent == .pdftotext ? .missing : .found),
                toolStatus(.chrome, .found)
            ])
            let availability = PackageAction.exportArtifacts.availability(report)
            XCTAssertFalse(availability.enabled, absent.displayName)
            XCTAssertEqual(availability.reason, "Export needs Pandoc, pdftotext, and Google Chrome. See Settings > External Tools.", absent.displayName)
        }

        let invalidExtractor = ToolAvailabilityReport(tools: [
            toolStatus(.pandoc, .found),
            toolStatus(.exportTool, .overrideInvalid)
        ])
        let invalid = PackageAction.exportArtifacts.availability(invalidExtractor)
        XCTAssertFalse(invalid.enabled)
        XCTAssertEqual(invalid.reason, "NAV_CENTER_EXPORT_BIN does not point to an executable file. See Settings > External Tools.")

        XCTAssertTrue(PackageAction.atsScan.availability(missingChrome).enabled)
        let sync = PackageAction.syncToVault.availability(missingChrome)
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.reason, "Reserved for a later confirmed vault sync workflow.")
    }

    func testExportRailStaysEnabledWhenExternalExportToolIsConfigured() {
        let external = ToolAvailabilityReport(tools: [
            toolStatus(.exportTool, .found),
            toolStatus(.pandoc, .missing),
            toolStatus(.pdftotext, .missing),
            toolStatus(.chrome, .missing)
        ])
        let configured = PackageAction.exportArtifacts.availability(external)
        XCTAssertTrue(configured.enabled)
        XCTAssertNil(configured.reason)

        let builtInReady = ToolAvailabilityReport(tools: [
            toolStatus(.exportTool, .builtIn),
            toolStatus(.pandoc, .found),
            toolStatus(.pdftotext, .found),
            toolStatus(.chrome, .found)
        ])
        XCTAssertTrue(PackageAction.exportArtifacts.availability(builtInReady).enabled)
    }

    @MainActor
    func testStoreLoadsArtifactsTabAfterConfirmedExport() async {
        let packageName = "2026-01-01_Synthetic_Engineer"
        let service = IntakeDashboardService()
        service.confirmedActionResult = ActionResultResponse(
            ok: true,
            action: DashboardAction(
                id: "action_export",
                action: "export-artifacts",
                label: "Export Resume Artifacts",
                packageName: packageName,
                status: "succeeded",
                requestedAt: "2026-01-01T00:00:00Z",
                completedAt: "2026-01-01T00:00:01Z",
                durationMs: 10,
                command: nil,
                outputPath: nil,
                exitCode: 0,
                signal: nil,
                message: "Resume artifacts exported: HTML, DOCX, PDF, and text extractions.",
                stdoutTail: "",
                stderrTail: ""
            )
        )
        let store = DashboardStore(service: service)
        store.selectedPackage = PackageResponse(
            generatedAt: "2026-01-01T00:00:00Z",
            package: ApplicationPackage(
                name: packageName,
                applicationDir: "applications/\(packageName)",
                metadata: [:],
                files: [],
                tabs: [],
                artifactSummary: ArtifactSummary(total: 0, previewable: 0, ats: 0, byFormat: [:], byKind: [:]),
                health: PackageHealth.empty
            ),
            application: nil,
            statusEvents: [],
            sources: dashboardSources()
        )
        store.activePackageTabKey = PackageTabKey.review.rawValue

        await store.runConfirmedAction("export-artifacts", packageName: packageName)

        XCTAssertEqual(service.lastAction?.actionKey, "export-artifacts")
        XCTAssertEqual(service.lastAction?.confirmed, true)
        XCTAssertEqual(store.activePackageTabKey, PackageTabKey.artifacts.rawValue)
        XCTAssertNil(store.errorMessage)
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
        store.activePackageTabKey = PackageTabKey.interviewPrep.rawValue

        store.leavePackageDetailForSidebarNavigation()

        XCTAssertNil(store.selectedPackage)
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
        XCTAssertNil(store.lastCodexAutomationOutcome)
    }

    @MainActor
    func testIntakeReportsBusyCodexInsteadOfSilentlyDroppingAutomation() async {
        let service = IntakeDashboardService()
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "Existing")
        let started = expectation(description: "Codex turn started")
        let release = DispatchSemaphore(value: 0)
        service.chatStarted = started
        service.chatRelease = release
        let turn = Task { await store.sendCodexMessage("Existing turn", allowEdits: false, confirmed: false) }
        await fulfillment(of: [started], timeout: 2)
        await store.createPackageFromIntake(intakeRequest(), runCodexAutomation: true)
        let name = "2099-04-01_Paste_Corp_Product_Security_Engineer"
        XCTAssertEqual(store.lastCodexAutomationOutcome, .busy)
        XCTAssertEqual(store.intakeMessage, "Created package: \(name). Codex automation did not start because another Codex turn is running. Open the package and send the build prompt from the Codex panel.")
        release.signal()
        _ = await turn.value
    }

    @MainActor
    func testIntakeReportsCodexFailureAfterPackageIsCreated() async {
        let service = IntakeDashboardService()
        service.chatError = DashboardAPIError.serverUnavailable("Synthetic Codex failure")
        let store = DashboardStore(service: service)
        await store.createPackageFromIntake(intakeRequest(), runCodexAutomation: true)
        XCTAssertEqual(service.createdRequests.count, 1)
        XCTAssertEqual(store.lastCodexAutomationOutcome, .failed("Synthetic Codex failure"))
        XCTAssertTrue(store.intakeMessage?.hasPrefix("Created package: 2099-04-01_Paste_Corp_Product_Security_Engineer. Codex automation failed:") == true)
    }

    @MainActor
    func testIntakeWithoutAutomationLeavesOutcomeNotRequested() async {
        let store = DashboardStore(service: IntakeDashboardService())
        await store.createPackageFromIntake(intakeRequest(), runCodexAutomation: false)
        XCTAssertNil(store.lastCodexAutomationOutcome)
        XCTAssertEqual(store.intakeMessage, "Created package: 2099-04-01_Paste_Corp_Product_Security_Engineer")
    }

    @MainActor
    func testPackageResponseCarriesStatusEventsFromFakeService() async {
        let service = IntakeDashboardService()
        service.statusEvents = [PackageStatusEvent(oldStatus: "Submitted", newStatus: "Interview", changedAt: "2099-04-02T12:00:00Z")]
        let store = DashboardStore(service: service)
        await store.loadPackage(named: "2099-04-01_Paste_Corp_Product_Security_Engineer")
        XCTAssertEqual(store.selectedPackage?.statusEvents, service.statusEvents)
    }

    @MainActor
    func testStatusChangeFromTablePublishesConfirmationMessage() async {
        let service = IntakeDashboardService()
        let store = DashboardStore(service: service)
        let application = ApplicationRecord(id: "app", packageName: "2099-04-01_Paste_Corp_Product_Security_Engineer", date: "", company: "", role: "", location: "", salary: "", status: "", nextActionDate: "", applicationDir: "", applyLink: "", sourceName: "", sourceId: "", notes: "", notesPreview: "", createdAt: "", updatedAt: "", source: .empty, health: .empty, files: [], dbArtifacts: [])
        await store.updateStatus(.submitted, for: application)
        XCTAssertEqual(store.statusMessage, "2099-04-01_Paste_Corp_Product_Security_Engineer: Submitted")
    }

    private func intakeRequest() -> JobDescriptionIntakeRequest {
        JobDescriptionIntakeRequest(company: "Paste Corp", role: "Product Security Engineer", postingText: "Synthetic posting", sourceURL: "", location: "", salary: "")
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

        await store.previewPackageCleanup(olderThanDays: 7)
        await store.applyPackageCleanup(olderThanDays: 7, deleteTracked: true)

        XCTAssertNil(store.cleanupPreview)
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
                "Resume source present",
                "PDF present",
                "DOCX present",
                "Extraction file present",
                "ATS available",
                "Interview prep"
            ]
        )
        XCTAssertEqual(checks.map(\.isPassing), [true, true, true, true, true, true, false])
    }

    @MainActor
    func testStoreBootstrapPublishesToolAvailabilityAndAppVersion() async {
        let report = ToolAvailabilityReport(tools: [
            ToolStatus(
                tool: .codex,
                state: .missing,
                resolvedPath: nil,
                source: nil,
                environmentVariable: "DASHBOARD_CODEX_BIN",
                installHint: "install the Codex CLI and sign in once from a terminal",
                summary: "missing"
            )
        ])
        let store = DashboardStore(service: ToolReportingDashboardService(report: report))

        await store.bootstrap()

        XCTAssertEqual(store.toolAvailability, report)
        XCTAssertEqual(store.appVersion, FeedbackDiagnostics.buildVersion)
        XCTAssertFalse(store.appVersion.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testServiceWithoutToolSupportLeavesSettingsTableEmptyNotErrored() async {
        let store = DashboardStore(service: IntakeDashboardService())

        await store.bootstrap()

        XCTAssertEqual(store.toolAvailability, .empty)
        XCTAssertNil(store.errorMessage)
    }

    private func toolStatus(_ tool: ExternalTool, _ state: ToolState) -> ToolStatus {
        ToolStatus(
            tool: tool,
            state: state,
            resolvedPath: state == .found ? "/usr/local/bin/\(tool.rawValue)" : nil,
            source: nil,
            environmentVariable: tool.environmentVariable,
            installHint: tool.installHint,
            summary: state.rawValue
        )
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

private final class IntakeDashboardService: DashboardServicing, @unchecked Sendable {
    let repoRoot = URL(fileURLWithPath: "/tmp/nav-center-intake-test")
    var createdRequests: [JobDescriptionIntakeRequest] = []
    var savedMasterResumeContent = ""
    var sentCodexRequests: [CodexChatRequest] = []
    var confirmedActionResult: ActionResultResponse?
    var lastAction: (packageName: String, actionKey: String, confirmed: Bool)?
    var chatStarted: XCTestExpectation?
    var chatRelease: DispatchSemaphore?
    var chatError: Error?
    var statusEvents: [PackageStatusEvent] = []

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

    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult {
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
            statusEvents: statusEvents,
            sources: Self.sources()
        )
    }

    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse {
        ActionLogResponse(generatedAt: "2099-04-01T12:00:00Z", localOnly: true, actions: [])
    }

    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse {
        lastAction = (packageName, actionKey, confirmed)
        if let confirmedActionResult { return confirmedActionResult }
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult {
        let json = "{\"applicationID\":\"app\",\"packageName\":\"\(packageName)\",\"oldStatus\":\"\",\"newStatus\":\"\(status.rawValue)\",\"changedAt\":\"2099-04-01T12:00:00Z\",\"warnings\":[]}"
        return try JSONDecoder().decode(TrackerStatusUpdateResult.self, from: Data(json.utf8))
    }

    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult {
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
        chatStarted?.fulfill()
        if let chatRelease { _ = chatRelease.wait(timeout: .now() + 5) }
        if let chatError { throw chatError }
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

private final class ToolReportingDashboardService: DashboardServicing, @unchecked Sendable {
    private let base = IntakeDashboardService()
    private let report: ToolAvailabilityReport

    init(report: ToolAvailabilityReport) {
        self.report = report
    }

    var repoRoot: URL { base.repoRoot }

    func fetchSummary() throws -> DashboardSummary { try base.fetchSummary() }
    func fetchApplications(limit: Int) throws -> ApplicationsResponse { try base.fetchApplications(limit: limit) }
    func fetchPackage(named packageName: String) throws -> PackageResponse { try base.fetchPackage(named: packageName) }
    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse {
        try base.fetchFilePreview(packageName: packageName, file: file)
    }
    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse {
        base.fetchActions(packageName: packageName, limit: limit)
    }
    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse {
        try base.runAction(packageName: packageName, actionKey: actionKey, confirmed: confirmed)
    }
    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult {
        try base.updatePackageStatus(packageName: packageName, status: status)
    }
    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview {
        try base.previewPackageCleanup(olderThanDays: olderThanDays)
    }
    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult {
        try base.applyPackageCleanup(olderThanDays: olderThanDays, deleteTracked: deleteTracked, expectedPreview: expectedPreview)
    }
    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument] { try base.importDocuments(urls) }
    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult {
        try base.createPackage(from: request)
    }
    func loadMasterResume() throws -> MasterResumeSnapshot { try base.loadMasterResume() }
    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult {
        try base.saveMasterResume(content: content, expectedContent: expectedContent)
    }
    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse {
        try base.prepareRealtimeInterviewKit(packageName: packageName, overwrite: overwrite)
    }
    func realtimeInterviewReviewPrompt(packageName: String) throws -> String {
        try base.realtimeInterviewReviewPrompt(packageName: packageName)
    }
    func localFileURL(packageName: String, relativePath: String) throws -> URL {
        try base.localFileURL(packageName: packageName, relativePath: relativePath)
    }
    func fetchCodexStatus() throws -> CodexStatusResponse { try base.fetchCodexStatus() }
    func startCodexLogin(type: String) throws -> CodexLoginStartResponse { try base.startCodexLogin(type: type) }
    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse { try base.sendCodexChat(payload) }

    func fetchToolAvailability() throws -> ToolAvailabilityReport { report }
}

private final class CleanupRefreshService: DashboardServicing, @unchecked Sendable {
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

    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult {
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

    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult {
        throw DashboardAPIError.serverUnavailable("not used")
    }

    func fetchPackage(named packageName: String) throws -> PackageResponse {
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
