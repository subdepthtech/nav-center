import SwiftUI
import PDFKit

private enum PackageDetailLayout {
    static let wideLayoutMinimumWidth: CGFloat = 980
    static let mainPaneMinimumWidth: CGFloat = 720
    static let railMinimumWidth: CGFloat = 240
    static let railIdealWidth: CGFloat = 280
    static let railMaximumWidth: CGFloat = 320
    static let reviewSideBySideMinimumWidth: CGFloat = 520
}

struct PackageDetailView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var pendingAction: PackageAction?

    var body: some View {
        guard let payload = store.selectedPackage else {
            return AnyView(EmptyStateView(title: "No package selected", message: "Open an application package from the Applications view."))
        }

        return AnyView(
            GeometryReader { proxy in
                if proxy.size.width >= PackageDetailLayout.wideLayoutMinimumWidth {
                    HSplitView {
                        PackageDetailMainPane(payload: payload)
                            .frame(
                                minWidth: PackageDetailLayout.mainPaneMinimumWidth,
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )

                        PackageRail(packageRecord: payload.package, pendingAction: $pendingAction)
                            .frame(
                                minWidth: PackageDetailLayout.railMinimumWidth,
                                idealWidth: PackageDetailLayout.railIdealWidth,
                                maxWidth: PackageDetailLayout.railMaximumWidth
                            )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    compactLayout(payload: payload)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        )
    }

    private func compactLayout(payload: PackageResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PackageDetailMainContent(payload: payload)

                PackageRailContent(packageRecord: payload.package, pendingAction: $pendingAction)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(24)
        }
    }
}

private struct PackageDetailMainContent: View {
    @EnvironmentObject private var store: DashboardStore
    var payload: PackageResponse
    var fillWorkspace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    store.closePackage()
                } label: {
                    Label("Applications", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()
                LocalOnlyPill()
            }

            PackageHeader(payload: payload)
            PackageTabs(packageRecord: payload.package)
            PackageWorkspace(payload: payload, fillAvailableHeight: fillWorkspace)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: fillWorkspace ? .infinity : nil,
                    alignment: .topLeading
                )
                .layoutPriority(fillWorkspace ? 1 : 0)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: fillWorkspace ? .infinity : nil,
            alignment: .topLeading
        )
    }
}

private struct PackageDetailMainPane: View {
    @EnvironmentObject private var store: DashboardStore
    var payload: PackageResponse

    var body: some View {
        if store.activePackageTabKey == PackageTabKey.review.rawValue {
            PackageDetailMainContent(payload: payload, fillWorkspace: true)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                PackageDetailMainContent(payload: payload)
                    .padding(24)
            }
        }
    }
}

private struct PackageHeader: View {
    var payload: PackageResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications / \(payload.application?.company.nonEmptyFallback(payload.package.company) ?? payload.package.company.nonEmptyFallback(payload.package.name))")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(payload.application?.role.nonEmptyFallback(payload.package.role) ?? payload.package.role.nonEmptyFallback(payload.package.name))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            metadataText
                            StatusBadge(payload.application?.status ?? "Package Only")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            metadataText
                            StatusBadge(payload.application?.status ?? "Package Only")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var metadataText: some View {
        HStack {
            Text(payload.application?.company.nonEmptyFallback(payload.package.company) ?? payload.package.company.nonEmptyFallback("Untracked package"))
            Text(payload.application?.location.nonEmptyFallback("Location unknown") ?? "Location unknown")
        }
    }
}

private struct PackageTabs: View {
    @EnvironmentObject private var store: DashboardStore
    var packageRecord: ApplicationPackage

    var body: some View {
        let tabSelection = Binding(
            get: { store.activePackageTabKey },
            set: { tabKey in Task { await store.loadTab(tabKey) } }
        )

        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                Picker("Package Tab", selection: tabSelection) {
                    ForEach(packageRecord.tabs) { tab in
                        Text(tab.label).tag(tab.key)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Package Tab", selection: tabSelection) {
                    ForEach(packageRecord.tabs) { tab in
                        Text(tab.label).tag(tab.key)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }
}

private struct PackageWorkspace: View {
    @EnvironmentObject private var store: DashboardStore
    var payload: PackageResponse
    var fillAvailableHeight = false

    var body: some View {
        let tabKey = store.activePackageTabKey
        let tab = payload.package.tabs.first(where: { $0.key == tabKey })

        Group {
            if tabKey == PackageTabKey.review.rawValue {
                ReviewWorkspace(packageRecord: payload.package, fillAvailableHeight: fillAvailableHeight)
            } else if tabKey == PackageTabKey.posting.rawValue {
                PostingWorkspace(application: payload.application, tab: tab, packageRecord: payload.package)
            } else if tabKey == PackageTabKey.interviewPrep.rawValue {
                InterviewPrepWorkspace(packageRecord: payload.package, tab: tab)
            } else if let tab {
                FileListWorkspace(tab: tab)
            } else {
                EmptyStateView(title: "Unknown package tab", message: "Choose one of the package detail tabs.")
            }
        }
    }
}

private struct ReviewWorkspace: View {
    var packageRecord: ApplicationPackage
    var fillAvailableHeight = false
    @State private var resumeMode = "pdf"
    @State private var postingMode = "preview"

    private var resumeSource: PackageFile? {
        packageRecord.files.first { $0.kind == "resume-source" }
    }

    private var resumeHTML: PackageFile? {
        packageRecord.files.first {
            $0.relativePath.range(of: #"^artifacts/Resume_[^/]+\.html$"#, options: .regularExpression) != nil
        }
    }

    private var resumePDF: PackageFile? {
        packageRecord.files.first {
            $0.relativePath.range(of: #"^artifacts/Resume_[^/]+\.pdf$"#, options: .regularExpression) != nil
        }
    }

    private var posting: PackageFile? {
        packageRecord.files.first { $0.relativePath == "posting.md" }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= PackageDetailLayout.reviewSideBySideMinimumWidth {
                HStack(alignment: .top, spacing: 16) {
                    resumePane
                        .frame(width: (proxy.size.width - 16) / 2)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                    postingPane
                        .frame(width: (proxy.size.width - 16) / 2)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    resumePane
                    postingPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            minHeight: fillAvailableHeight ? 420 : 660,
            maxHeight: fillAvailableHeight ? .infinity : nil
        )
        .layoutPriority(fillAvailableHeight ? 1 : 0)
    }

    private var resumePane: some View {
        ReviewPane(
            title: "Resume",
            subtitle: resumeSource?.relativePath ?? resumeHTML?.relativePath ?? "Package file missing",
            mode: $resumeMode,
            modes: [("pdf", "PDF"), ("markdown", "Markdown")]
        ) {
            if resumeMode == "pdf" {
                RawDocumentPreview(
                    file: resumePDF,
                    openPDFFile: resumePDF,
                    fallbackMessage: "No generated resume preview found yet."
                )
                    .frame(minHeight: 420, maxHeight: .infinity)
            } else if let resumeSource {
                FileTextPreview(file: resumeSource, rendered: true, loadOnAppear: true)
                    .frame(minHeight: 420, maxHeight: .infinity)
            } else {
                EmptyStateView(title: "No resume source", message: "No Resume_*.md source file found in this package.")
            }
        }
    }

    private var postingPane: some View {
        ReviewPane(
            title: "Job Description",
            subtitle: posting?.relativePath ?? "Package file missing",
            mode: $postingMode,
            modes: [("preview", "Preview"), ("markdown", "Markdown")]
        ) {
            if let posting {
                FileTextPreview(file: posting, rendered: true, loadOnAppear: true)
                    .frame(minHeight: 420, maxHeight: .infinity)
            } else {
                EmptyStateView(title: "No posting", message: "No posting.md found in this package.")
            }
        }
    }
}

private struct ReviewPane<Content: View>: View {
    var title: String
    var subtitle: String
    @Binding var mode: String
    var modes: [(id: String, label: String)]
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    titleBlock
                    Spacer()
                    modePicker
                }

                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    modePicker
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var modePicker: some View {
        Picker(title, selection: $mode) {
            ForEach(modes, id: \.id) { mode in
                Text(mode.label).tag(mode.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 190)
    }
}

private struct PostingWorkspace: View {
    var application: ApplicationRecord?
    var tab: PackageTab?
    var packageRecord: ApplicationPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                SummaryMetric(title: "Location", value: application?.location.nonEmptyFallback("Unknown") ?? "Unknown", detail: "Package metadata", systemImage: "mappin.and.ellipse")
                SummaryMetric(title: "Salary Range", value: application?.salary.nonEmptyFallback("Not listed") ?? "Not listed", detail: "Posting source", systemImage: "dollarsign")
                SummaryMetric(title: "Clearance", value: clearanceLabel, detail: "Local review", systemImage: "checkmark.shield")
                SummaryMetric(title: "Work Model", value: workModelLabel, detail: "Inferred", systemImage: "laptopcomputer")
            }

            FileListWorkspace(
                title: "Posting Details",
                files: tab?.files ?? packageRecord.files.filter { $0.relativePath == "posting.md" },
                emptyMessage: "No posting.md found in this package.",
                assumption: "Expected source: applications/<package>/posting.md",
                autoLoadSinglePreview: true
            )
        }
    }

    private var clearanceLabel: String {
        let text = "\(application?.role ?? "") \(application?.notes ?? "")".lowercased()
        if text.contains("ts/sci") || text.contains("ts sci") { return "Active TS/SCI" }
        if text.contains("secret") { return "Secret" }
        return "Review posting"
    }

    private var workModelLabel: String {
        let text = "\(application?.location ?? "") \(application?.role ?? "")".lowercased()
        if text.contains("remote") { return "Remote" }
        if text.contains("hybrid") { return "Hybrid" }
        if text.contains("on-site") || text.contains("onsite") { return "On-site" }
        return "Review posting"
    }
}

private struct InterviewPrepWorkspace: View {
    @EnvironmentObject private var store: DashboardStore
    var packageRecord: ApplicationPackage
    var tab: PackageTab?

    private var hasKit: Bool {
        packageRecord.files.contains { $0.relativePath == "interview-realtime-session.json" }
    }

    private var hasTranscript: Bool {
        packageRecord.files.contains { $0.relativePath == "interview-transcript.md" }
    }

    private var hasReview: Bool {
        packageRecord.files.contains { $0.relativePath == "interview-review.md" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                SummaryMetric(title: "Model", value: "gpt-realtime-2", detail: "Realtime interviewer", systemImage: "waveform")
                SummaryMetric(title: "Session Kit", value: hasKit ? "Ready" : "Missing", detail: "Client secret payload", systemImage: hasKit ? "checkmark.circle" : "circle")
                SummaryMetric(title: "Transcript", value: hasTranscript ? "Ready" : "Missing", detail: "Review source", systemImage: "doc.text")
                SummaryMetric(title: "Codex Review", value: hasReview ? "Written" : "Pending", detail: "After-action guidance", systemImage: "sparkles")
            }

            Panel("Realtime Interview") {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            actionButtons
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            actionButtons
                        }
                    }

                    if store.isPreparingInterviewKit {
                        ProgressView("Preparing realtime kit...")
                            .controlSize(.small)
                    }

                    if let message = store.interviewKitMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Live API testing uses `OPENAI_API_KEY` with the generated `interview-realtime-session.json` payload. The secret itself is not written into the package.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FileListWorkspace(
                title: "Interview Files",
                files: tab?.files ?? packageRecord.files.filter { $0.kind.hasPrefix("interview") },
                emptyMessage: "No interview files found in this package.",
                assumption: "Expected files: interview-prep.md, interview-realtime-session.json, interview-transcript.md, and interview-review.md",
                autoLoadSinglePreview: false
            )
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.prepareRealtimeInterviewKit(overwrite: hasKit) }
            } label: {
                Label(hasKit ? "Refresh Kit" : "Build Kit", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPreparingInterviewKit)

            Button {
                Task { await store.reviewRealtimeInterviewWithCodex() }
            } label: {
                Label("Codex Review", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(!hasTranscript || store.isCodexLoading)
        }
    }
}

private struct SummaryMetric: View {
    var title: String
    var value: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FileListWorkspace: View {
    var tab: PackageTab?
    var title: String?
    var files: [PackageFile]?
    var emptyMessage: String?
    var assumption: String?
    var autoLoadSinglePreview = false

    init(tab: PackageTab) {
        self.tab = tab
        self.title = nil
        self.files = nil
        self.emptyMessage = nil
        self.assumption = nil
    }

    init(
        title: String,
        files: [PackageFile],
        emptyMessage: String,
        assumption: String,
        autoLoadSinglePreview: Bool = false
    ) {
        self.tab = nil
        self.title = title
        self.files = files
        self.emptyMessage = emptyMessage
        self.assumption = assumption
        self.autoLoadSinglePreview = autoLoadSinglePreview
    }

    private var resolvedTitle: String {
        title ?? tab?.listTitle ?? "Package Files"
    }

    private var resolvedFiles: [PackageFile] {
        files ?? tab?.files ?? []
    }

    var body: some View {
        Panel(resolvedTitle) {
            if resolvedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    EmptyStateView(title: emptyMessage ?? tab?.emptyTitle ?? "No files found", message: assumption ?? tab?.assumption ?? "No files are available for this package tab.")
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("\(resolvedFiles.count) \(resolvedFiles.count == 1 ? "file" : "files")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(resolvedFiles) { file in
                        FileCard(file: file, autoLoad: autoLoadSinglePreview && resolvedFiles.count == 1)
                    }
                }
            }
        }
    }
}

private struct FileCard: View {
    @EnvironmentObject private var store: DashboardStore
    var file: PackageFile
    var autoLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.label)
                        .font(.headline)
                        .lineLimit(2)
                    Text(file.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(file.format.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.10), in: Capsule())
            }

            HStack {
                Text(file.kind.capitalized.replacingOccurrences(of: "-", with: " "))
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                Text(file.modifiedAt)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if file.previewable {
                Button(store.filePreview(for: file) == nil ? "Load Preview" : "Reload Preview") {
                    store.filePreviewCache[file.relativePath] = nil
                    Task { await store.loadFilePreview(file) }
                }
                .disabled(store.isFilePreviewLoading(file))
            } else {
                Text("\(file.format.uppercased()) preview not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = store.filePreviewError(for: file) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if store.isFilePreviewLoading(file) {
                ProgressView("Loading preview...")
                    .controlSize(.small)
            } else if let preview = store.filePreview(for: file) {
                FilePreviewContent(file: file, content: preview.content)
            } else if file.previewable {
                Text("Preview is loaded on demand from the local dashboard API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Binary artifacts stay listed but are not fetched or embedded by the client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .task {
            if autoLoad {
                await store.loadFilePreview(file)
            }
        }
    }
}

private struct FileTextPreview: View {
    @EnvironmentObject private var store: DashboardStore
    var file: PackageFile
    var rendered: Bool
    var loadOnAppear: Bool

    var body: some View {
        Group {
            if let preview = store.filePreview(for: file) {
                FilePreviewContent(file: file, content: preview.content, rendered: rendered)
            } else if let error = store.filePreviewError(for: file) {
                EmptyStateView(title: "Preview unavailable", message: error)
            } else if store.isFilePreviewLoading(file) {
                ProgressView("Loading preview...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Text("Preview has not been loaded yet.")
                        .foregroundStyle(.secondary)
                    Button("Load Preview") {
                        Task { await store.loadFilePreview(file) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if loadOnAppear {
                await store.loadFilePreview(file)
            }
        }
    }
}

private struct FilePreviewContent: View {
    var file: PackageFile
    var content: String
    var rendered = false

    var body: some View {
        ScrollView {
            if shouldRenderMarkdown {
                MarkdownPreviewText(content: contentWithoutFrontmatter(content))
                    .padding(22)
            } else {
                Text(formattedContent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(minHeight: 220, maxHeight: rendered ? .infinity : nil)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var formattedContent: String {
        if file.format.lowercased() == "json",
           let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldRenderMarkdown: Bool {
        rendered || file.format.lowercased() == "md" || file.relativePath.lowercased().hasSuffix(".md")
    }
}

private struct MarkdownPreviewText: View {
    var content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(markdownBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markdownBlocks: [MarkdownBlock] {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { MarkdownBlock(line: String($0)) }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .blank:
            Spacer(minLength: 4)
        case .heading(let level):
            Text(inlineMarkdown(block.text))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 8 : 4)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .body:
            Text(inlineMarkdown(block.text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title2
        case 2:
            return .headline
        default:
            return .subheadline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct MarkdownBlock {
    enum Kind {
        case blank
        case heading(Int)
        case bullet
        case body
    }

    var kind: Kind
    var text: String

    init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            kind = .blank
            text = ""
        } else if let heading = Self.parseHeading(trimmed) {
            kind = .heading(heading.level)
            text = heading.text
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            kind = .bullet
            text = String(trimmed.dropFirst(2))
        } else {
            kind = .body
            text = line
        }
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard (1...4).contains(level) else {
            return nil
        }

        let index = line.index(line.startIndex, offsetBy: level)
        guard index < line.endIndex, line[index] == " " else {
            return nil
        }

        return (level, String(line[line.index(after: index)...]))
    }
}

private struct RawDocumentPreview: View {
    @EnvironmentObject private var store: DashboardStore
    var file: PackageFile?
    var openPDFFile: PackageFile?
    var fallbackMessage: String

    var body: some View {
        if let file, let url = store.fileURL(for: file) {
            ZStack(alignment: .bottomTrailing) {
                if file.format.lowercased() == "pdf" {
                    PDFDocumentPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                } else {
                    EmptyStateView(title: "Preview unavailable", message: "Native inline preview is available for package-local PDF artifacts.")
                }
                if let pdf = openPDFFile.flatMap(store.fileURL(for:)) {
                    Link("Open PDF", destination: pdf)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(title: fallbackMessage, message: "Expected artifact: applications/<package>/artifacts/Resume_<package>.html and Resume_<package>.pdf")
        }
    }
}

private struct PDFDocumentPreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

private func contentWithoutFrontmatter(_ content: String) -> String {
    guard content.hasPrefix("---\n") else {
        return content
    }
    let parts = content.components(separatedBy: "\n---\n")
    if parts.count > 1 {
        return parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return content
}

private extension PackageTab {
    var listTitle: String {
        switch key {
        case PackageTabKey.resumeSource.rawValue:
            return "Resume Source"
        case PackageTabKey.notes.rawValue:
            return "Package Notes"
        case PackageTabKey.artifacts.rawValue:
            return "Generated Artifacts"
        case PackageTabKey.ats.rawValue:
            return "ATS Artifacts"
        case PackageTabKey.interviewPrep.rawValue:
            return "Interview Prep"
        default:
            return label
        }
    }

    var emptyTitle: String {
        switch key {
        case PackageTabKey.resumeSource.rawValue:
            return "No Resume_*.md source file found in this package."
        case PackageTabKey.notes.rawValue:
            return "No package note markdown found in this package."
        case PackageTabKey.artifacts.rawValue:
            return "No generated non-ATS artifacts found yet."
        case PackageTabKey.ats.rawValue:
            return "No ATS artifacts found for this package."
        case PackageTabKey.interviewPrep.rawValue:
            return "No interview-prep.md found in this package."
        default:
            return "No files found for this package tab."
        }
    }

    var assumption: String {
        switch key {
        case PackageTabKey.resumeSource.rawValue:
            return "Expected source: applications/<package>/Resume_<package>.md"
        case PackageTabKey.notes.rawValue:
            return "Expected root package markdown such as applications/<package>/keyterms-study-guide.md"
        case PackageTabKey.artifacts.rawValue:
            return "Expected files: applications/<package>/artifacts/<document>.html, .docx, .pdf, .txt"
        case PackageTabKey.ats.rawValue:
            return "Expected files: applications/<package>/artifacts/ats-report.json or artifacts/ats-*.{json,md,txt}"
        case PackageTabKey.interviewPrep.rawValue:
            return "Expected source: applications/<package>/interview-prep.md"
        default:
            return "No files are available for this package tab."
        }
    }
}

private struct PackageRail: View {
    var packageRecord: ApplicationPackage
    @Binding var pendingAction: PackageAction?

    var body: some View {
        ScrollView {
            PackageRailContent(packageRecord: packageRecord, pendingAction: $pendingAction)
                .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PackageRailContent: View {
    @EnvironmentObject private var store: DashboardStore
    var packageRecord: ApplicationPackage
    @Binding var pendingAction: PackageAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel("Package Health") {
                ForEach(PackageHealthCheck.items(for: packageRecord)) { check in
                    HealthRow(label: check.label, isPassing: check.isPassing)
                }
            }

            Panel("Status") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        StatusBadge(store.selectedPackage?.application?.status ?? "Package Only")
                        Spacer()
                    }
                    PackageStatusButtons(packageName: packageRecord.name)
                    if let message = store.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Panel("Quick Actions") {
                ForEach(PackageAction.railActions) { action in
                    Button {
                        if action.isEnabled {
                            pendingAction = action
                        }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(action.isPrimary ? .blue : .secondary)
                    .disabled(store.isRunningAction || !action.isEnabled)
                }

                if let pendingAction {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(pendingAction.confirmationTitle)
                            .font(.headline)
                        Text(pendingAction.message)
                            .foregroundStyle(.secondary)
                        if let command = pendingAction.commandPreview(packageName: packageRecord.name) {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                        HStack {
                            Button(pendingAction.title) {
                                let actionKey = pendingAction.rawValue
                                self.pendingAction = nil
                                Task { await store.runConfirmedAction(actionKey) }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Cancel") {
                                self.pendingAction = nil
                            }
                        }
                    }
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Panel("Action Log") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(store.actions.count) \(store.actions.count == 1 ? "entry" : "entries")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ItemList(items: Array(store.actions.prefix(8)), emptyMessage: "No action attempts for this package.") { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                StatusDot(status: action.status)
                                Text(action.label)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(action.status.capitalized)
                                    .foregroundStyle(.secondary)
                            }
                            Text(action.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let command = action.command {
                                Text(command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            if !action.stderrTail.isEmpty {
                                Text(action.stderrTail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                    }
                }
            }
        }
    }
}

private struct PackageStatusButtons: View {
    @EnvironmentObject private var store: DashboardStore
    var packageName: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons
            }

            VStack(alignment: .leading, spacing: 8) {
                buttons
            }
        }
    }

    private var buttons: some View {
        ForEach(TrackerStatusQuickAction.allCases) { action in
            Button {
                Task { await store.updatePackageStatus(action, packageName: packageName) }
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isUpdatingStatus || packageName.isEmpty)
            .help(action.help)
        }
    }
}

enum PackageAction: String, Identifiable {
    case atsScan = "ats-scan"
    case exportArtifacts = "export-artifacts"
    case syncToVault = "sync-to-vault"

    static let railActions: [PackageAction] = [.atsScan, .exportArtifacts, .syncToVault]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .atsScan: return "Run ATS Scan"
        case .exportArtifacts: return "Export Artifacts"
        case .syncToVault: return "Sync to Vault"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .atsScan: return "Confirm ATS Scan"
        case .exportArtifacts: return "Export Artifacts"
        case .syncToVault: return "Sync to Vault"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .atsScan: return true
        case .exportArtifacts, .syncToVault: return false
        }
    }

    var systemImage: String {
        switch self {
        case .atsScan: return "magnifyingglass"
        case .exportArtifacts: return "square.and.arrow.down"
        case .syncToVault: return "square.and.arrow.up"
        }
    }

    var isPrimary: Bool {
        self == .atsScan
    }

    var message: String {
        switch self {
        case .atsScan:
            return "Runs a local package scan and refreshes the package ATS report."
        case .exportArtifacts:
            return "Reserved for a later confirmed export workflow."
        case .syncToVault:
            return "Reserved for a later confirmed vault sync workflow."
        }
    }

    func commandPreview(packageName: String) -> String? {
        switch self {
        case .atsScan:
            let packagePath = "applications/\(packageName)"
            return "atsim scan \(packagePath) --out \(packagePath)/artifacts/ats-report.json"
        case .exportArtifacts, .syncToVault:
            return nil
        }
    }
}
