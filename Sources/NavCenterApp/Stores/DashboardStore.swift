import Foundation
import NavCenterCore

private struct CodexPackageConversation {
    var messages: [CodexChatMessage] = []
    var threadId: String?
}

protocol DashboardServicing: AnyObject, Sendable {
    var repoRoot: URL { get }

    func fetchSummary() throws -> DashboardSummary
    func fetchApplications(limit: Int) throws -> ApplicationsResponse
    func fetchPackage(named packageName: String) throws -> PackageResponse
    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse
    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse
    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse
    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult
    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview
    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool, expectedPreview: PackageCleanupPreview) throws -> PackageCleanupResult
    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument]
    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult
    func loadMasterResume() throws -> MasterResumeSnapshot
    func saveMasterResume(content: String, expectedContent: String?) throws -> MasterResumeSaveResult
    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse
    func realtimeInterviewReviewPrompt(packageName: String) throws -> String
    func localFileURL(packageName: String, relativePath: String) throws -> URL
    func fetchPDFPreviewData(packageName: String, relativePath: String) throws -> Data
    func fetchCodexStatus() throws -> CodexStatusResponse
    func startCodexLogin(type: String) throws -> CodexLoginStartResponse
    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse
    func cancelCodexTurn() throws
    func fetchToolAvailability() throws -> ToolAvailabilityReport
}

enum MasterResumeSaveOutcome: Equatable {
    case saved
    case notSaved(String)
}

extension DashboardServicing {
    func fetchPDFPreviewData(packageName: String, relativePath: String) throws -> Data {
        throw DashboardAPIError.serverUnavailable("PDF preview is not available.")
    }
    func cancelCodexTurn() throws { throw DashboardAPIError.serverUnavailable("This service does not support cancellation.") }
    func fetchToolAvailability() throws -> ToolAvailabilityReport { .empty }
    func fetchActions(packageName: String) -> ActionLogResponse {
        fetchActions(packageName: packageName, limit: 20)
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published var summary: DashboardSummary?
    @Published var applications: [ApplicationRecord] = []
    @Published var selectedPackage: PackageResponse?
    @Published var filePreviewCache: [String: PackageFilePreviewResponse] = [:]
    @Published var filePreviewLoading: Set<String> = []
    @Published var filePreviewErrors: [String: String] = [:]
    @Published var actions: [DashboardAction] = []
    @Published var codexStatus: CodexStatusResponse?
    @Published var codexLogin: CodexLoginStartResponse?
    @Published var codexMessages: [CodexChatMessage] = []
    @Published var codexThreadId: String?
    @Published var selectedApplication: ApplicationRecord?
    @Published var activePackageTabKey = PackageTabKey.review.rawValue
    @Published var isLoading = false
    @Published var isRunningAction = false
    @Published var isUpdatingStatus = false
    @Published var isLoadingCleanupPreview = false
    @Published var isRunningCleanup = false
    @Published var isCreatingPackage = false
    @Published var isCodexLoading = false
    @Published private(set) var isCodexTurnRunning = false
    @Published private(set) var isCancellingCodex = false
    @Published var isLoadingMasterResume = false
    @Published var isSavingMasterResume = false
    @Published var isImportingDocuments = false
    @Published var isPreparingInterviewKit = false
    @Published var intakeMessage: String?
    @Published var interviewKitMessage: String?
    @Published var statusMessage: String?
    @Published var cleanupPreview: PackageCleanupPreview?
    @Published var cleanupMessage: String?
    @Published var masterResumeSnapshot: MasterResumeSnapshot?
    @Published var masterResumeContent = ""
    @Published var masterResumeMessage: String?
    @Published var onboardingMessage: String?
    @Published var importedDocuments: [ImportedDocument] = []
    @Published var codexErrorMessage: String?
    @Published var errorMessage: String?
    @Published var toolAvailability: ToolAvailabilityReport?
    @Published var repoRootURL: URL?
    @Published var applicationSearch = ""
    @Published var dataWarningMessage: String?
    @Published private(set) var previewRevision = UUID()

    var hasUnsavedMasterResume: Bool {
        masterResumeContent != (masterResumeSnapshot?.content ?? "")
    }

    let appVersion: String = FeedbackDiagnostics.buildVersion
    private let service: DashboardServicing
    private var codexConversations: [String: CodexPackageConversation] = [:]
    private let serviceQueue = DispatchQueue(label: "nav-center.local-services", qos: .userInitiated)
    private let codexQueue = DispatchQueue(label: "nav-center.codex-services", qos: .userInitiated)
    private var selectionRevision = UUID()
    private var refreshRevision = UUID()
    private var loadingCount = 0

    init() {
        self.service = NativeDashboardService()
    }

    init(service: DashboardServicing) {
        self.service = service
    }

    private func background<T>(codex: Bool = false, _ work: @escaping (DashboardServicing) throws -> T) async throws -> T {
        let service = self.service
        let queue = codex ? codexQueue : serviceQueue
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(service) }) }
        }
    }

    private func beginLoading() { loadingCount += 1; isLoading = true }
    private func endLoading() { loadingCount -= 1; isLoading = loadingCount > 0 }

    private func invalidatePreviews() {
        filePreviewCache = [:]
        filePreviewLoading = []
        filePreviewErrors = [:]
        previewRevision = UUID()
    }

    private func refreshPackageIfCurrent(_ name: String, revision: UUID) async throws {
        guard selectedPackage?.package.name == name, selectionRevision == revision else { return }
        let previouslyLoaded = Set(filePreviewCache.keys)
        let result = try await background { service in
            (try service.fetchPackage(named: name), service.fetchActions(packageName: name))
        }
        guard selectedPackage?.package.name == name, selectionRevision == revision, !Task.isCancelled else { return }
        selectedPackage = result.0
        selectedApplication = result.0.application
        actions = result.1.actions
        invalidatePreviews()
        for file in result.0.package.files where previouslyLoaded.contains(file.relativePath) {
            guard selectedPackage?.package.name == name, selectionRevision == revision else { return }
            await loadFilePreview(file)
        }
    }

    func bootstrap() async {
        repoRootURL = service.repoRoot
        await refresh()
        await refreshToolAvailability()
    }

    func refreshToolAvailability() async {
        do {
            toolAvailability = try await background { try $0.fetchToolAvailability() }
        } catch is CancellationError {
            return
        } catch {
            toolAvailability = nil
        }
    }

    func refreshAll() async throws {
        let refresh = UUID()
        refreshRevision = refresh
        let selectedName = selectedPackage?.package.name
        let revision = selectionRevision
        let result = try await background { service in
            (try service.fetchSummary(), try service.fetchApplications(limit: Int.max))
        }
        guard refreshRevision == refresh, !Task.isCancelled else { return }
        summary = result.0
        applications = result.1.applications
        let warnings = result.0.sources.tracker.warnings + result.0.sources.packages.warnings
        dataWarningMessage = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        if let selectedApplication {
            self.selectedApplication = applications.first(where: { $0.id == selectedApplication.id }) ?? selectedApplication
        }
        if let selectedName { try await refreshPackageIfCurrent(selectedName, revision: revision) }
    }

    func refresh() async {
        beginLoading()
        defer { endLoading() }
        do { try await refreshAll() }
        catch is CancellationError {}
        catch {
            dataWarningMessage = "Local data could not be refreshed. Previously loaded data may be out of date. " + error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func openPackage(for application: ApplicationRecord) async {
        guard !application.packageName.isEmpty else {
            errorMessage = DashboardAPIError.missingPackageName.localizedDescription
            return
        }
        await loadPackage(named: application.packageName)
    }

    func loadPackage(named packageName: String) async {
        saveActiveCodexConversation()
        let revision = UUID()
        selectionRevision = revision
        beginLoading()
        defer { endLoading() }
        do {
            let result = try await background { service in
                (try service.fetchPackage(named: packageName), service.fetchActions(packageName: packageName))
            }
            guard selectionRevision == revision, !Task.isCancelled else { return }
            selectedPackage = result.0
            selectedApplication = result.0.application
            restoreCodexConversation(for: packageName)
            actions = result.1.actions
            interviewKitMessage = nil
            invalidatePreviews()
            if let tab = selectedPackage?.package.tabs.first(where: { $0.key == PackageTabKey.review.rawValue && $0.available })
                ?? selectedPackage?.package.tabs.first(where: { $0.available }) {
                selectTab(tab.key)
            }
        } catch is CancellationError {}
        catch { if selectionRevision == revision { errorMessage = error.localizedDescription } }
    }

    func filePreview(for file: PackageFile) -> PackageFilePreviewResponse? { filePreviewCache[file.relativePath] }
    func filePreviewError(for file: PackageFile) -> String? { filePreviewErrors[file.relativePath] }
    func isFilePreviewLoading(_ file: PackageFile) -> Bool { filePreviewLoading.contains(file.relativePath) }

    func loadFilePreview(_ file: PackageFile) async {
        guard let packageName = selectedPackage?.package.name, file.previewable else { return }
        guard filePreviewCache[file.relativePath] == nil, !filePreviewLoading.contains(file.relativePath) else { return }
        let revision = previewRevision
        let selection = selectionRevision
        filePreviewLoading.insert(file.relativePath)
        filePreviewErrors[file.relativePath] = nil
        defer { if previewRevision == revision { filePreviewLoading.remove(file.relativePath) } }
        do {
            let preview = try await background { try $0.fetchFilePreview(packageName: packageName, file: file.relativePath) }
            guard previewRevision == revision, selectionRevision == selection, !Task.isCancelled else { return }
            filePreviewCache[file.relativePath] = preview
        } catch is CancellationError {}
        catch { if previewRevision == revision, selectionRevision == selection { filePreviewErrors[file.relativePath] = error.localizedDescription } }
    }

    func selectTab(_ tabKey: String) {
        activePackageTabKey = tabKey
    }

    func runConfirmedAction(_ actionKey: String, packageName confirmedPackage: String? = nil) async {
        guard let packageName = confirmedPackage ?? selectedPackage?.package.name,
              selectedPackage?.package.name == packageName, !isRunningAction else { return }
        let revision = selectionRevision
        isRunningAction = true
        defer { isRunningAction = false }
        do {
            let result = try await background { try $0.runAction(packageName: packageName, actionKey: actionKey, confirmed: true) }
            try await refreshPackageIfCurrent(packageName, revision: revision)
            if !result.ok, selectedPackage?.package.name == packageName, selectionRevision == revision { errorMessage = result.action.message }
            if actionKey == "ats-scan", selectedPackage?.package.name == packageName, selectionRevision == revision {
                selectTab(PackageTabKey.ats.rawValue)
            }
        } catch {
            if selectedPackage?.package.name == packageName, selectionRevision == revision { errorMessage = error.localizedDescription }
        }
    }

    func updateStatus(_ action: TrackerStatusQuickAction, for application: ApplicationRecord) async {
        await updatePackageStatus(action, packageName: application.packageName)
    }

    func updatePackageStatus(_ action: TrackerStatusQuickAction, packageName: String) async {
        guard !packageName.isEmpty else { errorMessage = DashboardAPIError.missingPackageName.localizedDescription; return }
        guard !isUpdatingStatus else { return }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }
        do {
            let result = try await background { try $0.updatePackageStatus(packageName: packageName, status: action.trackerStatus) }
            statusMessage = (["\(result.packageName): \(result.newStatus)"] + result.warnings).joined(separator: " ")
            try await refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func previewPackageCleanup(olderThanDays: Int = 7) async {
        guard !isLoadingCleanupPreview, !isRunningCleanup else { return }
        isLoadingCleanupPreview = true
        defer { isLoadingCleanupPreview = false }
        do {
            cleanupPreview = try await background { try $0.previewPackageCleanup(olderThanDays: olderThanDays) }
            cleanupMessage = nil
        } catch { cleanupPreview = nil; errorMessage = error.localizedDescription }
    }

    func applyPackageCleanup(olderThanDays: Int = 7, deleteTracked: Bool = true, confirmedPreview: PackageCleanupPreview? = nil) async {
        guard !isRunningCleanup else {
            cleanupMessage = "Package cleanup is already running."
            return
        }
        guard let preview = confirmedPreview ?? cleanupPreview else {
            errorMessage = "Preview the packages before confirming cleanup."
            return
        }
        guard preview.olderThanDays == olderThanDays else {
            errorMessage = "The cleanup preview is stale because its age threshold no longer matches. Preview the packages again before confirming cleanup."
            return
        }
        isRunningCleanup = true
        defer { isRunningCleanup = false }
        do {
            let result = try await background { try $0.applyPackageCleanup(olderThanDays: olderThanDays, deleteTracked: deleteTracked, expectedPreview: preview) }
            let removedNames = Set(result.removedPackages.map(\.packageName))
            if let selectedName = selectedPackage?.package.name, removedNames.contains(selectedName) { closePackage() }
            cleanupMessage = (["Removed \(result.removedPackages.count) package\(result.removedPackages.count == 1 ? "" : "s"). Backup: \(result.backupURL.lastPathComponent)"] + result.warnings).joined(separator: " ")
            do {
                let refreshedPreview = try await background { try $0.previewPackageCleanup(olderThanDays: olderThanDays) }
                if refreshedPreview.candidates.isEmpty {
                    cleanupPreview = nil
                    cleanupMessage = (cleanupMessage ?? "Cleanup completed.") + " No additional packages match this cleanup preview."
                } else {
                    cleanupPreview = refreshedPreview
                }
            } catch {
                cleanupPreview = nil
                cleanupMessage = (cleanupMessage ?? "Cleanup completed.") + " Cleanup succeeded, but the next preview could not be refreshed. Preview again before another cleanup."
            }
            try await refreshAll()
        } catch { cleanupPreview = nil; errorMessage = error.localizedDescription }
    }

    func importSourceDocuments(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImportingDocuments else { return }
        isImportingDocuments = true
        defer { isImportingDocuments = false }
        do {
            let imported = try await background { try $0.importDocuments(urls) }
            importedDocuments = imported
            onboardingMessage = "Imported \(imported.count) source document\(imported.count == 1 ? "" : "s") for review."
        } catch { onboardingMessage = error.localizedDescription }
    }

    func createPackageFromIntake(_ request: JobDescriptionIntakeRequest, runCodexAutomation: Bool) async {
        let trimmed = request.trimmed
        guard !trimmed.company.isEmpty, !trimmed.role.isEmpty, !trimmed.postingText.isEmpty else {
            errorMessage = "Company, role, and pasted job description are required."
            return
        }
        guard !isCreatingPackage else { return }
        let revision = selectionRevision
        isCreatingPackage = true
        defer { isCreatingPackage = false }
        do {
            let result = try await background { try $0.createPackage(from: trimmed) }
            intakeMessage = "Created package: \(result.packageName)"
            try await refreshAll()
            if selectionRevision == revision { await loadPackage(named: result.packageName) }
            if runCodexAutomation {
                await sendCodexMessage(codexPackageBuildPrompt(packageName: result.packageName, request: trimmed), allowEdits: true, confirmed: true, packageName: result.packageName)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMasterResume(discardUnsavedChanges: Bool = false) async {
        guard !isLoadingMasterResume, !isSavingMasterResume else { return }
        guard discardUnsavedChanges || !hasUnsavedMasterResume else {
            masterResumeMessage = "Unsaved changes were kept. Save them or choose Reload and discard changes."
            return
        }
        let contentAtStart = masterResumeContent
        isLoadingMasterResume = true
        defer { isLoadingMasterResume = false }
        do {
            let snapshot = try await background { try $0.loadMasterResume() }
            guard masterResumeContent == contentAtStart, !Task.isCancelled else { return }
            masterResumeSnapshot = snapshot
            masterResumeContent = snapshot.content
            masterResumeMessage = nil
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func saveMasterResume() async -> MasterResumeSaveOutcome {
        guard !isSavingMasterResume, !isLoadingMasterResume else {
            let message = "Wait for the current master resume operation to finish, then save again. Your draft has been kept."
            errorMessage = message
            return .notSaved(message)
        }
        guard let expectedContent = masterResumeSnapshot?.content else {
            let message = "Load and review the saved master resume before saving changes. Your draft has been kept."
            errorMessage = message
            return .notSaved(message)
        }
        isSavingMasterResume = true
        defer { isSavingMasterResume = false }

        do {
            let content = masterResumeContent
            let result = try await background { try $0.saveMasterResume(content: content, expectedContent: expectedContent) }
            masterResumeSnapshot = MasterResumeSnapshot(
                relativePath: result.relativePath,
                content: content,
                modifiedAt: result.modifiedAt
            )
            if masterResumeContent == content {
                masterResumeMessage = "Saved \(result.relativePath)"
                return .saved
            }
            let message = "The earlier draft was saved, but newer edits remain unsaved. Save again before quitting."
            masterResumeMessage = message
            return .notSaved(message)
        } catch {
            let message = "The master resume could not be saved. Your draft has been kept. \(error.localizedDescription)"
            errorMessage = message
            return .notSaved(message)
        }
    }

    func prepareRealtimeInterviewKit(overwrite: Bool = false) async {
        guard let packageName = selectedPackage?.package.name, !isPreparingInterviewKit else { return }
        let revision = selectionRevision
        isPreparingInterviewKit = true
        defer { isPreparingInterviewKit = false }
        do {
            let response = try await background { try $0.prepareRealtimeInterviewKit(packageName: packageName, overwrite: overwrite) }
            try await refreshPackageIfCurrent(packageName, revision: revision)
            guard selectedPackage?.package.name == packageName, selectionRevision == revision else { return }
            interviewKitMessage = response.wroteFiles
                ? "Realtime kit ready: \(response.outputPaths.joined(separator: ", "))"
                : "Realtime kit is already current."
            selectTab(PackageTabKey.interviewPrep.rawValue)
        } catch {
            if selectedPackage?.package.name == packageName, selectionRevision == revision {
                interviewKitMessage = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    func reviewRealtimeInterviewWithCodex(confirmed: Bool = false, packageName: String? = nil) async {
        guard confirmed else {
            interviewKitMessage = "Confirm the package review and markdown edits before continuing."
            return
        }
        guard let name = packageName ?? selectedPackage?.package.name,
              selectedPackage?.package.name == name,
              selectedPackage?.package.files.contains(where: { $0.relativePath == "interview-transcript.md" }) == true else {
            interviewKitMessage = "Open the confirmed package and save its interview transcript before requesting review."
            return
        }
        guard codexStatus?.account != nil, !isCodexLoading else {
            interviewKitMessage = "Sign in using the Codex chat panel before requesting review."
            return
        }
        let revision = selectionRevision
        do {
            let prompt = try await background { try $0.realtimeInterviewReviewPrompt(packageName: name) }
            guard selectedPackage?.package.name == name, selectionRevision == revision else { return }
            await sendCodexMessage(prompt, allowEdits: true, confirmed: true, packageName: name)
            if selectedPackage?.package.name == name { interviewKitMessage = codexErrorMessage ?? "Codex review completed." }
        } catch {
            if selectedPackage?.package.name == name, selectionRevision == revision { interviewKitMessage = error.localizedDescription }
        }
    }

    func refreshCodexStatus() async {
        guard !isCodexLoading else { return }
        isCodexLoading = true
        defer { isCodexLoading = false }
        do {
            codexStatus = try await background(codex: true) { try $0.fetchCodexStatus() }
            codexErrorMessage = nil
        } catch {
            codexStatus = nil
            codexErrorMessage = error.localizedDescription
        }
    }

    func startCodexLogin(type: String = "chatgptDeviceCode") async {
        guard !isCodexLoading else { return }
        isCodexLoading = true
        defer { isCodexLoading = false }
        do {
            codexLogin = try await background(codex: true) { try $0.startCodexLogin(type: type) }
            codexErrorMessage = nil
        } catch { codexErrorMessage = error.localizedDescription }
    }

    func sendCodexMessage(_ message: String, allowEdits: Bool, confirmed: Bool, packageName: String? = nil) async {
        guard let name = packageName ?? selectedPackage?.package.name, !isCodexLoading else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !allowEdits || confirmed else {
            codexErrorMessage = "Confirm package markdown edits before sending."
            return
        }
        saveActiveCodexConversation()
        var conversation = codexConversations[name] ?? CodexPackageConversation()
        conversation.messages.append(CodexChatMessage(role: .user, text: trimmed))
        codexConversations[name] = conversation
        publishCodexConversation(for: name)
        if selectedPackage?.package.name == name { codexErrorMessage = nil }
        isCodexLoading = true
        isCodexTurnRunning = true
        defer { isCodexLoading = false; isCodexTurnRunning = false; isCancellingCodex = false }
        let request = CodexChatRequest(packageName: name, message: trimmed, threadId: conversation.threadId, allowEdits: allowEdits, confirmed: confirmed)
        do {
            let response = try await background(codex: true) { try $0.sendCodexChat(request) }
            conversation.threadId = response.threadId
            conversation.messages.append(CodexChatMessage(role: response.ok ? .assistant : .system, text: response.message.nonEmptyFallback(response.ok ? "Codex completed the turn without a final message." : "Codex could not complete the turn.")))
            codexConversations[name] = conversation
            publishCodexConversation(for: name)
            if selectedPackage?.package.name == name {
                codexErrorMessage = response.ok ? nil : response.message.nonEmptyFallback("Codex could not complete the turn.")
            }
            if allowEdits, response.ok { try await refreshPackageIfCurrent(name, revision: selectionRevision) }
        } catch {
            conversation.messages.append(CodexChatMessage(role: .system, text: error.localizedDescription))
            codexConversations[name] = conversation
            publishCodexConversation(for: name)
            if selectedPackage?.package.name == name { codexErrorMessage = error.localizedDescription }
        }
    }

    func cancelCodexTurn() async {
        guard isCodexTurnRunning, !isCancellingCodex else { return }
        isCancellingCodex = true
        let service = self.service
        do {
            try await Task.detached(priority: .userInitiated) { try service.cancelCodexTurn() }.value
        } catch {
            isCancellingCodex = false
            codexErrorMessage = error.localizedDescription
        }
    }

    private func publishCodexConversation(for name: String) {
        guard selectedPackage?.package.name == name else { return }
        let conversation = codexConversations[name] ?? CodexPackageConversation()
        codexMessages = conversation.messages
        codexThreadId = conversation.threadId
    }

    func closePackage() {
        saveActiveCodexConversation()
        selectionRevision = UUID()
        selectedPackage = nil
        filePreviewCache = [:]
        filePreviewLoading = []
        filePreviewErrors = [:]
        actions = []
        activePackageTabKey = PackageTabKey.review.rawValue
        interviewKitMessage = nil
        codexLogin = nil
        codexMessages = []
        codexThreadId = nil
        codexErrorMessage = nil
    }

    func leavePackageDetailForSidebarNavigation() {
        closePackage()
    }

    func fileURL(for file: PackageFile) -> URL? {
        guard let packageName = selectedPackage?.package.name else { return nil }
        return try? service.localFileURL(packageName: packageName, relativePath: file.relativePath)
    }

    func pdfPreviewData(for file: PackageFile) -> Data? {
        guard let packageName = selectedPackage?.package.name else { return nil }
        return try? service.fetchPDFPreviewData(packageName: packageName, relativePath: file.relativePath)
    }

    func validatedFileURL(for file: PackageFile) throws -> URL {
        guard let packageName = selectedPackage?.package.name else { throw DashboardAPIError.missingPackageName }
        return try service.localFileURL(packageName: packageName, relativePath: file.relativePath)
    }

    private func saveActiveCodexConversation() {
        guard let packageName = selectedPackage?.package.name else { return }
        codexConversations[packageName] = CodexPackageConversation(
            messages: codexMessages,
            threadId: codexThreadId
        )
    }

    private func restoreCodexConversation(for packageName: String) {
        let conversation = codexConversations[packageName] ?? CodexPackageConversation()
        codexMessages = conversation.messages
        codexThreadId = conversation.threadId
        codexErrorMessage = nil
    }

    private func codexPackageBuildPrompt(packageName: String, request: JobDescriptionIntakeRequest) -> String {
        [
            "Build this application package from the pasted posting.",
            "Package: applications/\(packageName)",
            "Company: \(request.company)",
            "Role: \(request.role)",
            request.sourceURL.isEmpty ? "" : "Source URL: \(request.sourceURL)",
            "",
            "Use applications/\(packageName)/posting.md and master-resumes/master_primary.yaml as the source of truth.",
            "Create or refresh the tailored resume markdown, optional cover letter markdown, and interview-prep.md.",
            "Do not add claims that are not supported by the master resume or the posting.",
            "Keep edits inside this package's allowed markdown files."
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
