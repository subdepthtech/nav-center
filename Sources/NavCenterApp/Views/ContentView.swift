import SwiftUI
import AppKit
import NavCenterCore

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var selection: DashboardDestination = .overview
    @State private var dashboardSearch = ""
    @State private var showingCodex = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView {
                List(DashboardDestination.allCases, selection: sidebarSelection) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
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
                        PackageDetailView()
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
                        TextField("Search dashboard", text: $dashboardSearch)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)

                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh local tracker and package data")
                        .disabled(store.isLoading)
                    }
                }
                .alert("Dashboard Error", isPresented: errorBinding) {
                    Button("OK") {
                        store.errorMessage = nil
                    }
                } message: {
                    Text(store.errorMessage ?? "")
                }
            }

            CodexChatLauncher(isPresented: $showingCodex)
                .environmentObject(store)
                .padding(22)
                .zIndex(1)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
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

private struct PackagesWorkspaceView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var showingCleanupConfirmation = false

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
        .confirmationDialog("Remove packages older than 7 days?", isPresented: $showingCleanupConfirmation, titleVisibility: .visible) {
            Button("Remove \(cleanupCandidates.count) Package\(cleanupCandidates.count == 1 ? "" : "s")", role: .destructive) {
                Task { await store.applyPackageCleanup(olderThanDays: 7, deleteTracked: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes package folders and matching tracker rows after writing a local backup and manifest.")
        }
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

                if !cleanupCandidates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(cleanupCandidates.prefix(8))) { candidate in
                            HStack(spacing: 10) {
                                Image(systemName: candidate.isTracked ? "checklist" : "folder")
                                    .foregroundStyle(candidate.isTracked ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.packageName)
                                        .lineLimit(1)
                                    Text(candidate.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 10)
                                Text(candidate.packageDate)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                            if candidate.id != cleanupCandidates.prefix(8).last?.id {
                                Divider()
                            }
                        }
                    }

                    if cleanupCandidates.count > 8 {
                        Text("+ \(cleanupCandidates.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            .help("Preview packages older than 7 days")

            Button(role: .destructive) {
                showingCleanupConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(cleanupCandidates.isEmpty || store.isLoadingCleanupPreview || store.isRunningCleanup)
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
                        TextField("Company", text: $company)
                        TextField("Role", text: $role)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Company", text: $company)
                        TextField("Role", text: $role)
                    }
                }
                .textFieldStyle(.roundedBorder)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("Source URL", text: $sourceURL)
                        TextField("Location", text: $location)
                        TextField("Salary", text: $salary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Source URL", text: $sourceURL)
                        TextField("Location", text: $location)
                        TextField("Salary", text: $salary)
                    }
                }
                .textFieldStyle(.roundedBorder)

                TextEditor(text: $postingText)
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
                    .toggleStyle(.checkbox)

                if runCodexAutomation {
                    HStack(spacing: 10) {
                        StatusBadge(codexReady ? "Codex Ready" : "Sign In Required")
                        Button {
                            Task { await store.refreshCodexStatus() }
                        } label: {
                            Label("Check", systemImage: "waveform.path.ecg")
                        }
                        .disabled(store.isCodexLoading)

                        if !codexReady {
                            Button {
                                Task { await store.startCodexLogin() }
                            } label: {
                                Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .disabled(store.isCodexLoading)
                        }

                        Toggle("Approve package markdown edits", isOn: $approveCodexEdits)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)

                    Text("\(postingText.trimmingCharacters(in: .whitespacesAndNewlines).count) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let message = store.intakeMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
    @State private var didLoad = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "Master Resume", subtitle: "Edit the canonical local YAML used for package tailoring.")

                    Panel("Editor") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Button {
                                    Task { await store.loadMasterResume() }
                                } label: {
                                    Label("Reload", systemImage: "arrow.clockwise")
                                }
                                .disabled(store.isLoadingMasterResume || store.isSavingMasterResume)

                                Button {
                                    Task { await store.saveMasterResume() }
                                } label: {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.masterResumeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoadingMasterResume || store.isSavingMasterResume)

                                if let snapshot = store.masterResumeSnapshot {
                                    Text(snapshot.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            TextEditor(text: $store.masterResumeContent)
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
            guard !didLoad else { return }
            didLoad = true
            await store.loadMasterResume()
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
                        Text("Package artifacts are opened from Package Detail > Artifacts.")
                        Text("Tracker CSV export remains local and is validated by the dashboard test suite.")
                        Text("Vault sync and bulk export actions stay disabled in-app until their confirmation gates are wired.")
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
                        .disabled(store.isLoading)
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
