import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OverviewView: View {
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    title: "Overview",
                    subtitle: "Private local status across tracker rows, packages, artifacts, ATS scans, and next actions."
                )

                onboardingPanel

                if let summary = store.summary {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], alignment: .leading, spacing: 12) {
                        StatCard(title: "Pursue Now", value: summary.totals.pursueNow, systemImage: "target")
                        StatCard(title: "Generated", value: summary.totals.generated, systemImage: "doc.text")
                        StatCard(title: "Submitted", value: summary.totals.submitted, systemImage: "paperplane")
                        StatCard(title: "Interviews", value: summary.totals.interviews, systemImage: "person.2")
                        StatCard(title: "Due", value: summary.totals.nextActionsDue, systemImage: "calendar.badge.clock")
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            pipelinePanel(summary)
                            nextActionsPanel(summary)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            pipelinePanel(summary)
                            nextActionsPanel(summary)
                        }
                    }

                    Panel("Recent Applications") {
                        ItemList(
                            items: summary.recentApplications,
                            emptyMessage: "No recent applications found."
                        ) { application in
                            ApplicationCompactRow(application: application)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No dashboard data loaded",
                        message: "The native app has not loaded local tracker and package data yet."
                    )
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var onboardingPanel: some View {
        Panel("Friends and Family Beta Setup") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import resumes, evaluations, education records, certifications, and related documents into the local workspace before generating the master resume.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        chooseSourceDocuments()
                    } label: {
                        Label("Import Source Docs", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isImportingDocuments)

                    if store.isImportingDocuments {
                        ProgressView()
                            .scaleEffect(0.75)
                    }
                }

                if let message = store.onboardingMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !store.importedDocuments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.importedDocuments, id: \.markdownRelativePath) { document in
                            Label(document.markdownRelativePath, systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func chooseSourceDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Import Source Documents"
        panel.message = "Choose resumes, evaluations, education records, certifications, or related documents to copy into the local Nav Center workspace."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .plainText,
            .text,
            .pdf,
            .rtf,
            .json,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "yaml") ?? .plainText,
            UTType(filenameExtension: "yml") ?? .plainText
        ]
        if panel.runModal() == .OK {
            Task { await store.importSourceDocuments(panel.urls) }
        }
    }

    private func pipelinePanel(_ summary: DashboardSummary) -> some View {
        Panel("Pipeline by Status") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.statusCounts.sorted(by: { $0.key < $1.key }), id: \.key) { status, count in
                    HStack {
                        StatusBadge(status)
                        Spacer()
                        Text("\(count)")
                            .font(.headline)
                    }
                    Divider()
                }
                HStack {
                    Label("\(summary.totals.trackerRows) tracker rows", systemImage: "tablecells")
                    Spacer()
                    Label("\(summary.totals.packageOnly) untracked packages", systemImage: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func nextActionsPanel(_ summary: DashboardSummary) -> some View {
        Panel("Next Actions") {
            ItemList(
                items: summary.upcomingActions,
                emptyMessage: "No dated next actions yet."
            ) { application in
                ApplicationCompactRow(application: application)
            }
        }
    }
}
