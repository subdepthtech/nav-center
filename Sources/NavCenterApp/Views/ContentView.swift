import SwiftUI
import AppKit
import NavCenterCore

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var selection: DashboardDestination = .overview
    @FocusState private var searchFocused: Bool
    @State private var noticeDismissal: Task<Void, Never>?
    @State private var availableHeight: CGFloat = LayoutMetrics.minimumWindowSize.height

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView {
                List(DashboardDestination.allCases, selection: sidebarSelection) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                        .accessibilityIdentifier(AccessibilityID.sidebar(destination))
                        .accessibilityLabel(destination.title)
                }
                .listStyle(.sidebar)
                .navigationTitle("Nav Center")

                VStack(alignment: .leading, spacing: 8) {
                    LocalOnlyPill()
                    if let url = store.repoRootURL {
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding()
            } detail: {
                ZStack {
                    if store.selectedPackage != nil {
                        PackageDetailView(isSearchFocused: searchFocused, unfocusSearch: { searchFocused = false })
                    } else {
                        switch selection {
                        case .overview:
                            OverviewView()
                        case .applications:
                            ApplicationsView()
                        case .packages:
                            PackagesWorkspaceView()
                        case .searches:
                            JobSearchesWorkspaceView()
                        case .resume:
                            MasterResumeWorkspaceView()
                        case .exports:
                            ExportsWorkspaceView()
                        case .settings:
                            SettingsWorkspaceView()
                        }
                    }

                    if store.isLoading && store.summary == nil {
                        ProgressView("Loading local dashboard...")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .toolbar {
                    ToolbarItemGroup {
                        TextField("Search applications", text: $store.applicationSearch)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .accessibilityIdentifier(AccessibilityID.toolbarSearch)
                            .accessibilityLabel("Search applications")
                            .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)

                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.toolbarRefresh)
                        .help("Refresh local tracker and package data")
                        .disabled(store.isLoading)
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let warning = store.dataWarningMessage {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12))
                    }
                }
                .alert("Dashboard Error", isPresented: errorBinding) {
                    Button("OK") {
                        store.errorMessage = nil
                    }
                    .accessibilityIdentifier(AccessibilityID.dashboardErrorOK)
                } message: {
                    Text(store.errorMessage ?? "")
                }
            }

            CodexChatLauncher(isPresented: $store.isCodexPanelPresented, windowHeight: availableHeight)
                .environmentObject(store)
                .padding(22)
                .zIndex(1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: AvailableHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(AvailableHeightKey.self) { availableHeight = $0 }
        .onAppear { applyRequestedDestination() }
        .onChange(of: store.requestedDestination) { _ in
            applyRequestedDestination()
        }
        .onChange(of: store.searchFocusRequest) { _ in searchFocused = true }
        .onChange(of: store.noticeMessage) { message in
            noticeDismissal?.cancel()
            guard let message else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
            noticeDismissal = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { store.noticeMessage = nil }
            }
        }
        .overlay(alignment: .top) {
            if let message = store.noticeMessage {
                HStack {
                    Text(message)
                    Button("Dismiss") { store.noticeMessage = nil }
                        .accessibilityIdentifier(AccessibilityID.noticeBannerDismiss)
                        .help("Dismiss diagnostics notice")
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                        }
                }
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .padding()
            }
        }
        .onChange(of: store.applicationSearch) { query in
            guard !query.isEmpty else { return }
            store.leavePackageDetailForSidebarNavigation()
            selection = .applications
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func applyRequestedDestination() {
        if let destination = store.applyRequestedDestination() { selection = destination }
    }

    private var sidebarSelection: Binding<DashboardDestination> {
        Binding(
            get: { selection },
            set: { destination in
                store.leavePackageDetailForSidebarNavigation()
                selection = destination
            }
        )
    }
}

private struct AvailableHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = LayoutMetrics.minimumWindowSize.height
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PackagesWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var cleanupReview: CleanupReviewRequest?

    private var packagedApplications: [ApplicationRecord] {
        store.applications.filter { !$0.packageName.isEmpty }
    }

    private var cleanupCandidates: [PackageCleanupCandidate] {
        store.cleanupPreview?.candidates ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Packages", subtitle: "Package health, source files, generated artifacts, and local review readiness.")
                dashboardStats([
                    ("Packages", store.summary?.totals.packages ?? packagedApplications.count, "folder"),
                    ("With Posting", store.summary?.packageHealth.withPosting ?? 0, "doc.text"),
                    ("With Resume", store.summary?.packageHealth.withResumeSource ?? 0, "person.text.rectangle"),
                    ("With Artifacts", store.summary?.packageHealth.withArtifacts ?? 0, "archivebox"),
                    ("With ATS", store.summary?.packageHealth.withAtsFiles ?? 0, "checklist"),
                ])

                cleanupPanel

                Panel("Recent Packages") {
                    packageRows(packagedApplications.prefix(14).map { $0 })
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $cleanupReview) { request in
            cleanupReviewSheet(request)
        }
    }

    private func cleanupReviewSheet(_ request: CleanupReviewRequest) -> some View {
        let rows = CleanupReviewModel.rows(for: request.preview)
        let tracked = rows.filter(\.isTracked).count
        let packageOnly = rows.count - tracked
        let count = rows.count
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove \(count) package\(count == 1 ? "" : "s") older than \(request.preview.olderThanDays) days?")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dated before \(request.preview.cutoffDate) · \(tracked) tracked, \(packageOnly) package-only")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("This removes package folders and matching tracker rows after writing a local backup and manifest.")
                .fixedSize(horizontal: false, vertical: true)

            cleanupCandidateList(rows, maxHeight: 320)

            HStack {
                Spacer()
                Button("Cancel") {
                    cleanupReview = nil
                }
                .accessibilityIdentifier(AccessibilityID.cleanupSheetCancel)
                .keyboardShortcut(.cancelAction)
                Button("Remove \(count) Packages", role: .destructive) {
                    Task { await store.applyPackageCleanup(olderThanDays: request.preview.olderThanDays, deleteTracked: true, confirmedPreview: request.preview) }
                    cleanupReview = nil
                }
                .accessibilityIdentifier(AccessibilityID.cleanupSheetConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 480, alignment: .leading)
    }

    private var cleanupPanel: some View {
        Panel("7-Day Cleanup") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cleanupSummary
                        Spacer(minLength: 12)
                        cleanupControls
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        cleanupSummary
                        cleanupControls
                    }
                }

                if let message = store.cleanupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let preview = store.cleanupPreview, !preview.candidates.isEmpty {
                    cleanupCandidateList(CleanupReviewModel.rows(for: preview), maxHeight: 280)
                }
            }
        }
    }

    private func cleanupCandidateList(_ rows: [CleanupReviewRow], maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    cleanupCandidateRow(row, showsDivider: row.id != rows.last?.id)
                }
            }
        }
        .frame(maxHeight: maxHeight)
    }

    private func cleanupCandidateRow(_ row: CleanupReviewRow, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: row.isTracked ? "checklist" : "folder")
                    .foregroundStyle(row.isTracked ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.packageName)
                        .lineLimit(1)
                    Text(row.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Text(row.packageDate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)

            if showsDivider {
                Divider()
            }
        }
    }

    private var cleanupSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(cleanupCandidates.count) old package\(cleanupCandidates.count == 1 ? "" : "s")")
                .font(.headline)
            Text(cleanupBreakdown)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanupBreakdown: String {
        guard let preview = store.cleanupPreview else {
            return "Preview packages dated before the 7-day cutoff."
        }
        let tracked = preview.candidates.filter(\.isTracked).count
        let packageOnly = preview.candidates.count - tracked
        return "Before \(preview.cutoffDate): \(tracked) tracked, \(packageOnly) package-only"
    }

    private var cleanupControls: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.previewPackageCleanup(olderThanDays: 7) }
            } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoadingCleanupPreview || store.isRunningCleanup)
            .accessibilityIdentifier(AccessibilityID.cleanupPreview)
            .help("Preview packages older than 7 days")

            Button(role: .destructive) {
                if let preview = store.cleanupPreview {
                    cleanupReview = CleanupReviewRequest(preview: preview)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(cleanupCandidates.isEmpty || store.isLoadingCleanupPreview || store.isRunningCleanup)
            .accessibilityIdentifier(AccessibilityID.cleanupRemove)
            .help("Remove previewed packages")
        }
    }

    private func packageRows(_ applications: [ApplicationRecord]) -> some View {
        ItemList(items: applications, emptyMessage: "No package folders were found under applications/.") { application in
            PackageListRow(application: application, fallbackTitle: "Untracked package")
        }
    }
}

private struct JobSearchesWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore

    private var sourcedApplications: [ApplicationRecord] {
        store.applications.filter { $0.status.lowercased().contains("sourced") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Job Searches", subtitle: "Local sourcing pass status and package-backed leads.")
                dashboardStats([
                    ("Sourced", sourcedApplications.count, "magnifyingglass"),
                    ("Pursue Now", store.summary?.totals.pursueNow ?? 0, "target"),
                    ("Due", store.summary?.totals.nextActionsDue ?? 0, "calendar.badge.clock"),
                ])
                JobDescriptionPastePanel()
                Panel("Recent Sourced Leads") {
                    packageRows(sourcedApplications.prefix(14).map { $0 })
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func packageRows(_ applications: [ApplicationRecord]) -> some View {
        ItemList(items: applications, emptyMessage: "No sourced leads are currently listed in the local tracker.") { application in
            PackageListRow(application: application, fallbackTitle: "Untracked lead")
        }
    }
}

private struct JobDescriptionPastePanel: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var company = ""
    @State private var role = ""
    @State private var sourceURL = ""
    @State private var location = ""
    @State private var salary = ""
    @State private var postingText = ""
    @State private var runCodexAutomation = false
    @State private var approveCodexEdits = false

    private var request: JobDescriptionIntakeRequest {
        JobDescriptionIntakeRequest(
            company: company,
            role: role,
            postingText: postingText,
            sourceURL: sourceURL,
            location: location,
            salary: salary
        )
    }

    private var codexReady: Bool {
        store.codexStatus?.account != nil
    }

    private var canCreate: Bool {
        let trimmed = request.trimmed
        let basicFieldsReady = !trimmed.company.isEmpty && !trimmed.role.isEmpty && trimmed.postingText.count >= 300
        let codexGateReady = !runCodexAutomation || (codexReady && approveCodexEdits)
        return basicFieldsReady && codexGateReady && !store.isCreatingPackage && !store.isCodexLoading
    }

    var body: some View {
        Panel("Paste Job Description") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("Company", text: $company).accessibilityIdentifier(AccessibilityID.intakeCompany)
                        TextField("Role", text: $role).accessibilityIdentifier(AccessibilityID.intakeRole)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Company", text: $company).accessibilityIdentifier(AccessibilityID.intakeCompany)
                        TextField("Role", text: $role).accessibilityIdentifier(AccessibilityID.intakeRole)
                    }
                }
                .textFieldStyle(.roundedBorder)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("Source URL", text: $sourceURL).accessibilityIdentifier(AccessibilityID.intakeSourceURL)
                        TextField("Location", text: $location).accessibilityIdentifier(AccessibilityID.intakeLocation)
                        TextField("Salary", text: $salary).accessibilityIdentifier(AccessibilityID.intakeSalary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Source URL", text: $sourceURL).accessibilityIdentifier(AccessibilityID.intakeSourceURL)
                        TextField("Location", text: $location).accessibilityIdentifier(AccessibilityID.intakeLocation)
                        TextField("Salary", text: $salary).accessibilityIdentifier(AccessibilityID.intakeSalary)
                    }
                }
                .textFieldStyle(.roundedBorder)

                TextEditor(text: $postingText)
                    .accessibilityIdentifier(AccessibilityID.intakePosting)
                    .accessibilityLabel("Full job description")
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if postingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Paste full job description")
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Toggle("Create with Codex automation", isOn: $runCodexAutomation)
                    .accessibilityIdentifier(AccessibilityID.intakeAutomation)
                    .toggleStyle(.checkbox)

                if runCodexAutomation {
                    HStack(spacing: 10) {
                        StatusBadge(codexReady ? "Codex Ready" : "Sign In Required")
                        Button {
                            Task { await store.refreshCodexStatus() }
                        } label: {
                            Label("Check", systemImage: "waveform.path.ecg")
                        }
                        .accessibilityIdentifier(AccessibilityID.intakeRefreshCodex)
                        .disabled(store.isCodexLoading)

                        if !codexReady {
                            Button {
                                Task { await store.startCodexLogin() }
                            } label: {
                                Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .accessibilityIdentifier(AccessibilityID.intakeCodexSignIn)
                            .disabled(store.isCodexLoading)
                        }

                        Toggle("Approve package markdown edits", isOn: $approveCodexEdits)
                            .accessibilityIdentifier(AccessibilityID.intakeApproveEdits)
                            .toggleStyle(.checkbox)
                    }
                    .font(.callout)

                    if let login = store.codexLogin, !codexReady {
                        HStack(spacing: 10) {
                            if let userCode = login.userCode {
                                Text("Code \(userCode)")
                                    .font(.caption.monospacedDigit())
                                    .textSelection(.enabled)
                            }
                            if let url = codexLoginURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Open", systemImage: "arrow.up.right.square")
                                }
                                .accessibilityIdentifier(AccessibilityID.intakeCodexLoginOpen)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await store.createPackageFromIntake(request, runCodexAutomation: runCodexAutomation)
                        }
                    } label: {
                        Label(runCodexAutomation ? "Create + Codex" : "Create Package", systemImage: "shippingbox.and.arrow.backward")
                    }
                    .accessibilityIdentifier(AccessibilityID.intakeCreate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)

                    Text("\(postingText.trimmingCharacters(in: .whitespacesAndNewlines).count) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let message = store.intakeMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        }
    }

    private var codexLoginURL: URL? {
        guard let value = store.codexLogin?.verificationUrl ?? store.codexLogin?.authUrl else { return nil }
        return URL(string: value)
    }
}

enum MasterResumeEditorLayout {
    static let minimumEditorHeight: CGFloat = 320
    static let maximumEditorHeight: CGFloat = 620
    static let verticalChromeHeight: CGFloat = 190
    static let floatingLauncherClearance: CGFloat = 96

    static func editorHeight(forViewportHeight viewportHeight: CGFloat) -> CGFloat {
        let availableHeight = viewportHeight - verticalChromeHeight - floatingLauncherClearance
        return min(max(availableHeight, minimumEditorHeight), maximumEditorHeight)
    }
}

private struct MasterResumeWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var showingDiscardConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "Master Resume", subtitle: "Edit the canonical local YAML used for package tailoring.")

                    Panel("Editor") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Button {
                                    if store.hasUnsavedMasterResume {
                                        showingDiscardConfirmation = true
                                    } else {
                                        Task { await store.loadMasterResume() }
                                    }
                                } label: {
                                    Label("Reload", systemImage: "arrow.clockwise")
                                }
                                .accessibilityIdentifier(AccessibilityID.resumeReload)
                                .disabled(store.isLoadingMasterResume || store.isSavingMasterResume)

                                Button {
                                    Task { await store.saveMasterResume() }
                                } label: {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }
                                .accessibilityIdentifier(AccessibilityID.resumeSave)
                                .buttonStyle(.borderedProminent)
                                .disabled(store.masterResumeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoadingMasterResume || store.isSavingMasterResume)

                                if let snapshot = store.masterResumeSnapshot {
                                    Text(snapshot.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            if store.hasUnsavedMasterResume {
                                Label("Unsaved changes", systemImage: "pencil.circle")
                                    .font(.caption)
                            }
                            TextEditor(text: $store.masterResumeContent)
                                .accessibilityIdentifier(AccessibilityID.resumeEditor)
                                .accessibilityLabel("Master resume YAML")
                                .disabled(store.isLoadingMasterResume)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: MasterResumeEditorLayout.editorHeight(forViewportHeight: proxy.size.height))
                                .scrollContentBackground(.hidden)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                            if let message = store.masterResumeMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, MasterResumeEditorLayout.floatingLauncherClearance)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if store.masterResumeSnapshot == nil { await store.loadMasterResume() }
        }
        .confirmationDialog("Discard unsaved master resume changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard and Reload", role: .destructive) {
                Task { await store.loadMasterResume(discardUnsavedChanges: true) }
            }
            .accessibilityIdentifier(AccessibilityID.resumeDiscard)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(AccessibilityID.resumeCancel)
        } message: {
            Text("Your unsaved edits will be replaced by the saved local master resume. Save your edits first if you want to keep them.")
        }
    }
}

private struct PackageListRow: View {
    @EnvironmentObject private var store: DashboardStore
    var application: ApplicationRecord
    var fallbackTitle: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                textBlock
                Spacer(minLength: 12)
                rowActions
            }

            VStack(alignment: .leading, spacing: 10) {
                textBlock
                rowActions
            }
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(application.company.nonEmptyFallback(fallbackTitle))
                .fontWeight(.medium)
                .lineLimit(1)
            Text(application.role.nonEmptyFallback(application.packageName))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(application.location.nonEmptyFallback(application.packageName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var rowActions: some View {
        HStack(spacing: 10) {
            StatusBadge(application.status)
            Button("Open") {
                Task { await store.openPackage(for: application) }
            }
            .accessibilityIdentifier(AccessibilityID.applicationsOpen(application.packageName))
            .disabled(application.packageName.isEmpty)
        }
    }
}

private struct ExportsWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Exports", subtitle: "Generated resume, cover letter, DOCX, PDF, text extraction, and tracker export status.")
                dashboardStats([
                    ("Artifacts", store.summary?.totals.artifacts ?? 0, "archivebox"),
                    ("Generated", store.summary?.totals.generated ?? 0, "doc.text"),
                    ("Submitted", store.summary?.totals.submitted ?? 0, "paperplane"),
                    ("With Artifacts", store.summary?.packageHealth.withArtifacts ?? 0, "folder.badge.gearshape"),
                ])
                Panel("Export Surfaces") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Export a package's resume from Package Detail > Quick Actions > Export Artifacts (confirmation required).")
                        Text("Package artifacts are opened from Package Detail > Artifacts.")
                        Text("Tracker CSV export remains local and is validated by the dashboard test suite.")
                        Text("Vault sync and bulk export stay disabled in-app until their confirmation gates are wired.")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct SettingsWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Settings", subtitle: "Local workspace and privacy status for this native dashboard.")
                Panel("About") {
                    settingRow("Version", store.appVersion)
                }
                Panel("Local Data") {
                    VStack(alignment: .leading, spacing: 10) {
                        settingRow("Workspace", store.repoRootURL?.path ?? "Not connected")
                        settingRow("Mode", "Direct Swift services")
                        settingRow("Tracker", store.summary?.sources.tracker.available == true ? "Available" : "Unavailable")
                        settingRow("Packages scanned", "\(store.summary?.sources.packages.scanned ?? 0)")
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh Local Data", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsRefresh)
                        .disabled(store.isLoading)
                    }
                }
                Panel("External Tools") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let report = store.toolAvailability {
                            ForEach(report.tools) { status in
                                toolStatusRow(status)
                            }
                        } else {
                            Text("Tool status is not available from this service.")
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.externalToolsFooter)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await store.refreshToolAvailability() }
                        } label: {
                            Label("Re-check Tools", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsRecheckTools)
                        .help("Probe the optional tools again without running them")
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private static let externalToolsFooter = ToolProbe.finderPathNotice + " Paths shown here are not redacted; CLI and feedback output are."

    private func toolStateLabel(_ state: ToolState) -> String {
        switch state {
        case .found: return "Found"
        case .missing: return "Missing"
        case .overrideInvalid: return "Override invalid"
        case .builtIn: return "Built-in"
        }
    }

    private func toolStatusRow(_ status: ToolStatus) -> some View {
        let stateLabel = toolStateLabel(status.state)
        let installLine = toolInstallLine(status)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.tool.displayName)
                Spacer(minLength: 12)
                Text(stateLabel)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(status.environmentVariable ?? "-")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(status.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let installLine {
                Text(installLine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toolAccessibilityLabel(status, stateLabel: stateLabel, installLine: installLine))
    }

    private func toolInstallLine(_ status: ToolStatus) -> String? {
        switch status.state {
        case .missing:
            return "Install: \(status.installHint)"
        case .overrideInvalid:
            let variable = status.environmentVariable ?? "the override"
            return "Fix or unset \(variable), or: \(status.installHint)"
        case .found, .builtIn:
            return nil
        }
    }

    private func toolAccessibilityLabel(_ status: ToolStatus, stateLabel: String, installLine: String?) -> String {
        let base = "\(status.tool.displayName): \(stateLabel). \(status.summary)"
        guard let installLine else { return base }
        return "\(base). \(installLine)"
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private func dashboardStats(_ stats: [(title: String, value: Int, systemImage: String)]) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
        ForEach(stats, id: \.title) { stat in
            StatCard(title: stat.title, value: stat.value, systemImage: stat.systemImage)
        }
    }
}
