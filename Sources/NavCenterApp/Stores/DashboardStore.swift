import Foundation
import NavCenterCore

private struct CodexPackageConversation {
    var messages: [CodexChatMessage] = []
    var threadId: String?
}

protocol DashboardServicing: AnyObject {
    var repoRoot: URL { get }

    func fetchSummary() throws -> DashboardSummary
    func fetchApplications(limit: Int) throws -> ApplicationsResponse
    func fetchPackage(named packageName: String) throws -> PackageResponse
    func fetchTab(packageName: String, tabKey: String, file: String?) throws -> PackageTabPreviewResponse
    func fetchFilePreview(packageName: String, file: String) throws -> PackageFilePreviewResponse
    func fetchActions(packageName: String, limit: Int) -> ActionLogResponse
    func runAction(packageName: String, actionKey: String, confirmed: Bool) throws -> ActionResultResponse
    func updatePackageStatus(packageName: String, status: TrackerStatus) throws -> TrackerStatusUpdateResult
    func previewPackageCleanup(olderThanDays: Int) throws -> PackageCleanupPreview
    func applyPackageCleanup(olderThanDays: Int, deleteTracked: Bool) throws -> PackageCleanupResult
    func importDocuments(_ urls: [URL]) throws -> [ImportedDocument]
    func createPackage(from request: JobDescriptionIntakeRequest) throws -> CreateApplicationResult
    func loadMasterResume() throws -> MasterResumeSnapshot
    func saveMasterResume(content: String) throws -> MasterResumeSaveResult
    func prepareRealtimeInterviewKit(packageName: String, overwrite: Bool) throws -> RealtimeInterviewKitResponse
    func realtimeInterviewReviewPrompt(packageName: String) throws -> String
    func localFileURL(packageName: String, relativePath: String) throws -> URL
    func fetchCodexStatus() throws -> CodexStatusResponse
    func startCodexLogin(type: String) throws -> CodexLoginStartResponse
    func sendCodexChat(_ payload: CodexChatRequest) throws -> CodexChatResponse
}

extension DashboardServicing {
    func fetchActions(packageName: String) -> ActionLogResponse {
        fetchActions(packageName: packageName, limit: 20)
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published var summary: DashboardSummary?
    @Published var applications: [ApplicationRecord] = []
    @Published var selectedPackage: PackageResponse?
    @Published var selectedTabPreview: PackageTabPreviewResponse?
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
    @Published var repoRootURL: URL?

    private let service: DashboardServicing
    private var codexConversations: [String: CodexPackageConversation] = [:]

    init() {
        self.service = NativeDashboardService()
    }

    init(service: DashboardServicing) {
        self.service = service
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            repoRootURL = service.repoRoot
            try await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async throws {
        summary = try service.fetchSummary()
        applications = try service.fetchApplications(limit: 500).applications
        if let selectedApplication {
            self.selectedApplication = applications.first(where: { $0.id == selectedApplication.id }) ?? selectedApplication
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openPackage(for application: ApplicationRecord) async {
        selectedApplication = application
        guard !application.packageName.isEmpty else {
            errorMessage = DashboardAPIError.missingPackageName.localizedDescription
            return
        }
        await loadPackage(named: application.packageName)
    }

    func loadPackage(named packageName: String) async {
        saveActiveCodexConversation()
        isLoading = true
        defer { isLoading = false }
        do {
            selectedPackage = try service.fetchPackage(named: packageName)
            restoreCodexConversation(for: packageName)
            actions = service.fetchActions(packageName: packageName).actions
            interviewKitMessage = nil
            filePreviewCache = [:]
            filePreviewLoading = []
            filePreviewErrors = [:]
            if let tab = selectedPackage?.package.tabs.first(where: { $0.key == PackageTabKey.review.rawValue && $0.available })
                ?? selectedPackage?.package.tabs.first(where: { $0.available }) {
                activePackageTabKey = tab.key
                await loadTab(tab.key)
            } else {
                selectedTabPreview = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func filePreview(for file: PackageFile) -> PackageFilePreviewResponse? {
        filePreviewCache[file.relativePath]
    }

    func filePreviewError(for file: PackageFile) -> String? {
        filePreviewErrors[file.relativePath]
    }

    func isFilePreviewLoading(_ file: PackageFile) -> Bool {
        filePreviewLoading.contains(file.relativePath)
    }

    func loadFilePreview(_ file: PackageFile) async {
        guard let packageName = selectedPackage?.package.name, file.previewable else { return }
        guard filePreviewCache[file.relativePath] == nil, !filePreviewLoading.contains(file.relativePath) else { return }

        filePreviewLoading.insert(file.relativePath)
        filePreviewErrors[file.relativePath] = nil
        defer { filePreviewLoading.remove(file.relativePath) }

        do {
            filePreviewCache[file.relativePath] = try service.fetchFilePreview(packageName: packageName, file: file.relativePath)
        } catch {
            filePreviewErrors[file.relativePath] = error.localizedDescription
        }
    }

    func loadTab(_ tabKey: String, file: PackageFile? = nil) async {
        guard let packageName = selectedPackage?.package.name else { return }
        do {
            activePackageTabKey = tabKey
            selectedTabPreview = try service.fetchTab(packageName: packageName, tabKey: tabKey, file: file?.relativePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runConfirmedAction(_ actionKey: String) async {
        guard let packageName = selectedPackage?.package.name else { return }
        isRunningAction = true
        defer { isRunningAction = false }
        do {
            _ = try service.runAction(packageName: packageName, actionKey: actionKey, confirmed: true)
            actions = service.fetchActions(packageName: packageName).actions
            selectedPackage = try service.fetchPackage(named: packageName)
            if actionKey == "ats-scan" {
                await loadTab(PackageTabKey.ats.rawValue)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateStatus(_ action: TrackerStatusQuickAction, for application: ApplicationRecord) async {
        await updatePackageStatus(action, packageName: application.packageName)
    }

    func updatePackageStatus(_ action: TrackerStatusQuickAction, packageName: String) async {
        guard !packageName.isEmpty else {
            errorMessage = DashboardAPIError.missingPackageName.localizedDescription
            return
        }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        do {
            let result = try service.updatePackageStatus(packageName: packageName, status: action.trackerStatus)
            statusMessage = "\(result.packageName): \(result.newStatus)"
            try await refreshAll()
            if selectedPackage?.package.name == packageName {
                selectedPackage = try service.fetchPackage(named: packageName)
                selectedApplication = selectedPackage?.application ?? applications.first { $0.packageName == packageName }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewPackageCleanup(olderThanDays: Int = 7) async {
        isLoadingCleanupPreview = true
        defer { isLoadingCleanupPreview = false }

        do {
            cleanupPreview = try service.previewPackageCleanup(olderThanDays: olderThanDays)
            cleanupMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyPackageCleanup(olderThanDays: Int = 7, deleteTracked: Bool = true) async {
        isRunningCleanup = true
        defer { isRunningCleanup = false }

        do {
            let result = try service.applyPackageCleanup(olderThanDays: olderThanDays, deleteTracked: deleteTracked)
            let removedNames = Set(result.removedPackages.map(\.packageName))
            if let selectedName = selectedPackage?.package.name, removedNames.contains(selectedName) {
                closePackage()
            }
            cleanupMessage = "Removed \(result.removedPackages.count) package\(result.removedPackages.count == 1 ? "" : "s"). Backup: \(result.backupURL.lastPathComponent)"
            cleanupPreview = try service.previewPackageCleanup(olderThanDays: olderThanDays)
            try await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importSourceDocuments(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImportingDocuments = true
        defer { isImportingDocuments = false }
        do {
            let imported = try service.importDocuments(urls)
            importedDocuments = imported
            onboardingMessage = "Imported \(imported.count) source document\(imported.count == 1 ? "" : "s") for review."
        } catch {
            onboardingMessage = error.localizedDescription
        }
    }

    func createPackageFromIntake(_ request: JobDescriptionIntakeRequest, runCodexAutomation: Bool) async {
        let trimmed = request.trimmed
        guard !trimmed.company.isEmpty, !trimmed.role.isEmpty, !trimmed.postingText.isEmpty else {
            errorMessage = "Company, role, and pasted job description are required."
            return
        }

        isCreatingPackage = true
        defer { isCreatingPackage = false }

        do {
            let service = self.service
            let result = try await Task.detached(priority: .userInitiated) {
                try service.createPackage(from: trimmed)
            }.value
            intakeMessage = "Created package: \(result.packageName)"
            try await refreshAll()
            await loadPackage(named: result.packageName)
            if runCodexAutomation {
                await sendCodexMessage(
                    codexPackageBuildPrompt(packageName: result.packageName, request: trimmed),
                    allowEdits: true,
                    confirmed: true
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMasterResume() async {
        isLoadingMasterResume = true
        defer { isLoadingMasterResume = false }

        do {
            let service = self.service
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try service.loadMasterResume()
            }.value
            masterResumeSnapshot = snapshot
            masterResumeContent = snapshot.content
            masterResumeMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveMasterResume() async {
        isSavingMasterResume = true
        defer { isSavingMasterResume = false }

        do {
            let content = masterResumeContent
            let service = self.service
            let result = try await Task.detached(priority: .userInitiated) {
                try service.saveMasterResume(content: content)
            }.value
            masterResumeSnapshot = MasterResumeSnapshot(
                relativePath: result.relativePath,
                content: content,
                modifiedAt: result.modifiedAt
            )
            masterResumeMessage = "Saved \(result.relativePath)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareRealtimeInterviewKit(overwrite: Bool = false) async {
        guard let packageName = selectedPackage?.package.name else { return }
        isPreparingInterviewKit = true
        defer { isPreparingInterviewKit = false }

        do {
            let service = self.service
            let response = try await Task.detached(priority: .userInitiated) {
                try service.prepareRealtimeInterviewKit(packageName: packageName, overwrite: overwrite)
            }.value
            selectedPackage = try service.fetchPackage(named: packageName)
            filePreviewCache = [:]
            filePreviewLoading = []
            filePreviewErrors = [:]
            actions = service.fetchActions(packageName: packageName).actions
            interviewKitMessage = response.wroteFiles
                ? "Realtime kit ready: \(response.outputPaths.joined(separator: ", "))"
                : "Realtime kit is already current."
            await loadTab(PackageTabKey.interviewPrep.rawValue)
        } catch {
            interviewKitMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func reviewRealtimeInterviewWithCodex() async {
        guard let packageName = selectedPackage?.package.name else { return }
        guard selectedPackage?.package.files.contains(where: { $0.relativePath == "interview-transcript.md" }) == true else {
            codexErrorMessage = "Build the realtime interview kit and paste the saved transcript into interview-transcript.md before asking Codex for review."
            return
        }

        do {
            let service = self.service
            let prompt = try await Task.detached(priority: .userInitiated) {
                try service.realtimeInterviewReviewPrompt(packageName: packageName)
            }.value
            activePackageTabKey = PackageTabKey.interviewPrep.rawValue
            await sendCodexMessage(prompt, allowEdits: true, confirmed: true)
        } catch {
            codexErrorMessage = error.localizedDescription
        }
    }

    func refreshCodexStatus() async {
        do {
            let service = self.service
            codexStatus = try await Task.detached(priority: .userInitiated) {
                try service.fetchCodexStatus()
            }.value
            codexErrorMessage = nil
        } catch {
            codexErrorMessage = error.localizedDescription
        }
    }

    func startCodexLogin(type: String = "chatgptDeviceCode") async {
        isCodexLoading = true
        defer { isCodexLoading = false }
        do {
            let service = self.service
            codexLogin = try await Task.detached(priority: .userInitiated) {
                try service.startCodexLogin(type: type)
            }.value
            codexErrorMessage = nil
        } catch {
            codexErrorMessage = error.localizedDescription
        }
    }

    func sendCodexMessage(_ message: String, allowEdits: Bool, confirmed: Bool) async {
        await Task.yield()
        guard let packageName = selectedPackage?.package.name else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCodexLoading = true
        codexMessages.append(CodexChatMessage(role: .user, text: trimmed))
        saveActiveCodexConversation()
        defer { isCodexLoading = false }

        do {
            let service = self.service
            let request = CodexChatRequest(
                packageName: packageName,
                message: trimmed,
                threadId: codexThreadId,
                allowEdits: allowEdits,
                confirmed: confirmed
            )
            let response = try await Task.detached(priority: .userInitiated) {
                try service.sendCodexChat(request)
            }.value
            codexThreadId = response.threadId
            codexMessages.append(CodexChatMessage(role: .assistant, text: response.message.nonEmptyFallback("Codex completed the turn without a final message.")))
            saveActiveCodexConversation()
            codexStatus = try? await Task.detached(priority: .utility) {
                try service.fetchCodexStatus()
            }.value
            codexErrorMessage = nil
            if allowEdits {
                selectedPackage = try service.fetchPackage(named: packageName)
                if let tab = selectedPackage?.package.tabs.first(where: { $0.key == activePackageTabKey }) {
                    await loadTab(tab.key)
                }
            }
        } catch {
            codexErrorMessage = error.localizedDescription
            codexMessages.append(CodexChatMessage(role: .system, text: error.localizedDescription))
            saveActiveCodexConversation()
        }
    }

    func closePackage() {
        saveActiveCodexConversation()
        selectedPackage = nil
        selectedTabPreview = nil
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
        guard selectedPackage != nil else { return }
        closePackage()
    }

    func fileURL(for file: PackageFile) -> URL? {
        guard let packageName = selectedPackage?.package.name else { return nil }
        return try? service.localFileURL(packageName: packageName, relativePath: file.relativePath)
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
