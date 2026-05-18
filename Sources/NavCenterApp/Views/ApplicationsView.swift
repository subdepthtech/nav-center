import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var store: DashboardStore
    @State private var searchText = ""
    @State private var statusFilter = ApplicationsFilterDefaults.status
    @State private var locationFilter = ApplicationsFilterDefaults.location
    @State private var sourceFilter = ApplicationsFilterDefaults.source
    @State private var currentPage = 0

    private let rowsPerPage = 12

    private var statusOptions: [String] {
        [ApplicationsFilterDefaults.status] + uniqueValues(store.applications.map(\.status))
    }

    private var locationOptions: [String] {
        [ApplicationsFilterDefaults.location] + uniqueValues(store.applications.map(\.location))
    }

    private var sourceOptions: [String] {
        [ApplicationsFilterDefaults.source] + uniqueValues(store.applications.map(sourceLabel))
    }

    private var filteredApplications: [ApplicationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.applications.filter { application in
            let matchesStatus = statusFilter == ApplicationsFilterDefaults.status || application.status == statusFilter
            let matchesLocation = locationFilter == ApplicationsFilterDefaults.location || application.location == locationFilter
            let matchesSource = sourceFilter == ApplicationsFilterDefaults.source || sourceLabel(for: application) == sourceFilter
            let matchesQuery = query.isEmpty || [
                application.company,
                application.role,
                application.location,
                application.status,
                application.salary,
                application.packageName,
                application.sourceName
            ].joined(separator: " ").localizedCaseInsensitiveContains(query)

            return matchesStatus && matchesLocation && matchesSource && matchesQuery
        }
    }

    private var pageCount: Int {
        max(Int(ceil(Double(filteredApplications.count) / Double(rowsPerPage))), 1)
    }

    private var safePage: Int {
        min(currentPage, pageCount - 1)
    }

    private var pagedApplications: [ApplicationRecord] {
        let start = safePage * rowsPerPage
        guard start < filteredApplications.count else { return [] }
        let end = min(start + rowsPerPage, filteredApplications.count)
        return Array(filteredApplications[start..<end])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterBar
                applicationsTable
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: searchText) { _ in resetPage() }
        .onChange(of: statusFilter) { _ in resetPage() }
        .onChange(of: locationFilter) { _ in resetPage() }
        .onChange(of: sourceFilter) { _ in resetPage() }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            horizontalFilterBar
            stackedFilterBar
        }
    }

    private var horizontalFilterBar: some View {
        HStack(spacing: 12) {
            ApplicationsSearchField(text: $searchText)
                .frame(minWidth: 240, idealWidth: 500, maxWidth: 520)

            ApplicationsFilterMenu(title: ApplicationsFilterDefaults.status, selection: $statusFilter, options: statusOptions)
                .frame(width: 150)

            ApplicationsFilterMenu(title: ApplicationsFilterDefaults.location, selection: $locationFilter, options: locationOptions)
                .frame(width: 160)

            ApplicationsFilterMenu(title: ApplicationsFilterDefaults.source, selection: $sourceFilter, options: sourceOptions)
                .frame(width: 145)

            Spacer(minLength: 0)
        }
    }

    private var stackedFilterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApplicationsSearchField(text: $searchText)
                .frame(maxWidth: .infinity)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.status, selection: $statusFilter, options: statusOptions)
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.location, selection: $locationFilter, options: locationOptions)
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.source, selection: $sourceFilter, options: sourceOptions)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.status, selection: $statusFilter, options: statusOptions)
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.location, selection: $locationFilter, options: locationOptions)
                    ApplicationsFilterMenu(title: ApplicationsFilterDefaults.source, selection: $sourceFilter, options: sourceOptions)
                }
            }
        }
    }

    private var applicationsTable: some View {
        ViewThatFits(in: .horizontal) {
            fullApplicationsTable
            compactApplicationsList
        }
    }

    private var fullApplicationsTable: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ApplicationsHeaderRow()
                Divider()

                if pagedApplications.isEmpty {
                    EmptyStateView(title: "No matching applications", message: "Try a broader search or clear the filters.")
                        .frame(minHeight: 320)
                } else {
                    ForEach(pagedApplications) { application in
                        ApplicationTableRow(application: application) {
                            Task { await store.openPackage(for: application) }
                        }
                        Divider()
                    }
                }
            }
            .frame(width: ApplicationsLayout.tableWidth, alignment: .leading)

            ApplicationsTableFooter(
                shownCount: pagedApplications.count,
                filteredCount: filteredApplications.count,
                currentPage: safePage,
                pageCount: pageCount,
                rowsPerPage: rowsPerPage,
                goBack: goBack,
                goForward: goForward
            )
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .frame(width: ApplicationsLayout.tableWidth, alignment: .leading)
    }

    private var compactApplicationsList: some View {
        VStack(spacing: 0) {
            if pagedApplications.isEmpty {
                EmptyStateView(title: "No matching applications", message: "Try a broader search or clear the filters.")
                    .frame(minHeight: 260)
            } else {
                VStack(spacing: 12) {
                    ForEach(pagedApplications) { application in
                        ApplicationCompactCard(application: application) {
                            Task { await store.openPackage(for: application) }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            ApplicationsTableFooter(
                shownCount: pagedApplications.count,
                filteredCount: filteredApplications.count,
                currentPage: safePage,
                pageCount: pageCount,
                rowsPerPage: rowsPerPage,
                goBack: goBack,
                goForward: goForward
            )
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func resetPage() {
        currentPage = 0
    }

    private func goBack() {
        currentPage = max(safePage - 1, 0)
    }

    private func goForward() {
        currentPage = min(safePage + 1, pageCount - 1)
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func sourceLabel(for application: ApplicationRecord) -> String {
        switch (application.source.tracker, application.source.package) {
        case (true, true):
            return "Tracker + Package"
        case (true, false):
            return "Tracker"
        case (false, true):
            return "Package"
        default:
            return application.sourceName.nonEmptyFallback("Unknown")
        }
    }
}

private enum ApplicationsFilterDefaults {
    static let status = "Status"
    static let location = "Location"
    static let source = "Source"
}

private enum ApplicationsLayout {
    static let tableWidth: CGFloat = 1535
    static let dateWidth: CGFloat = 125
    static let companyWidth: CGFloat = 190
    static let roleWidth: CGFloat = 355
    static let locationWidth: CGFloat = 190
    static let statusWidth: CGFloat = 135
    static let salaryWidth: CGFloat = 175
    static let nextActionWidth: CGFloat = 135
    static let actionWidth: CGFloat = 230
}

private struct ApplicationsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search companies, roles, or keywords...", text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct ApplicationsFilterMenu: View {
    var title: String
    @Binding var selection: String
    var options: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.isEmpty ? title : selection)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct ApplicationsHeaderRow: View {
    var body: some View {
        HStack(spacing: 0) {
            tableHeader("Date", width: ApplicationsLayout.dateWidth)
            tableHeader("Company", width: ApplicationsLayout.companyWidth)
            tableHeader("Role", width: ApplicationsLayout.roleWidth)
            tableHeader("Location", width: ApplicationsLayout.locationWidth)
            tableHeader("Status", width: ApplicationsLayout.statusWidth)
            tableHeader("Salary", width: ApplicationsLayout.salaryWidth)
            tableHeader("Next Action\nDate", width: ApplicationsLayout.nextActionWidth)
            tableHeader("", width: ApplicationsLayout.actionWidth)
        }
        .padding(.vertical, 18)
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .frame(width: width, alignment: .leading)
    }
}

private struct ApplicationTableRow: View {
    var application: ApplicationRecord
    var openPackage: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tableCell(application.date.nonEmptyFallback("—"), width: ApplicationsLayout.dateWidth)
            tableCell(application.company.nonEmptyFallback("Untracked"), width: ApplicationsLayout.companyWidth)
            roleCell
                .padding(.horizontal, 14)
                .frame(width: ApplicationsLayout.roleWidth, alignment: .leading)
            tableCell(application.location.nonEmptyFallback("—"), width: ApplicationsLayout.locationWidth)
            statusCell
                .padding(.horizontal, 14)
                .frame(width: ApplicationsLayout.statusWidth, alignment: .leading)
            tableCell(application.salary.nonEmptyFallback("—"), width: ApplicationsLayout.salaryWidth)
            tableCell(application.nextActionDate.nonEmptyFallback("—"), width: ApplicationsLayout.nextActionWidth, weight: .semibold)
            actionCell
                .padding(.horizontal, 14)
                .frame(width: ApplicationsLayout.actionWidth, alignment: .trailing)
        }
        .font(.callout)
        .frame(minHeight: 84)
    }

    private var roleCell: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(application.role.nonEmptyFallback(application.packageName.nonEmptyFallback("Package")))
                .fontWeight(.semibold)
                .lineLimit(2)
            ApplicationHealthStrip(application: application)
        }
    }

    private var statusCell: some View {
        StatusBadge(application.status)
    }

    private var actionCell: some View {
        HStack(spacing: 8) {
            StatusActionButtons(application: application)

            Button {
                openPackage()
            } label: {
                Label("Open Package", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(application.packageName.isEmpty)
            .help(application.packageName.isEmpty ? "No local package is available for this application." : "Open Package Detail")
        }
    }

    private func tableCell(_ text: String, width: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .fontWeight(weight)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .frame(width: width, alignment: .leading)
    }
}

private struct ApplicationCompactCard: View {
    var application: ApplicationRecord
    var openPackage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 12)
                    StatusBadge(application.status)
                }

                VStack(alignment: .leading, spacing: 8) {
                    titleBlock
                    StatusBadge(application.status)
                }
            }

            ApplicationHealthStrip(application: application)

            VStack(alignment: .leading, spacing: 6) {
                compactField("Location", application.location.nonEmptyFallback("—"))
                compactField("Salary", application.salary.nonEmptyFallback("—"))
                compactField("Next Action", application.nextActionDate.nonEmptyFallback("—"))
            }
            .font(.caption)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    StatusActionButtons(application: application, controlSize: .regular)
                    openPackageButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    StatusActionButtons(application: application, controlSize: .regular)
                    openPackageButton
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(application.company.nonEmptyFallback("Untracked"))
                .foregroundStyle(.secondary)
            Text(application.role.nonEmptyFallback(application.packageName.nonEmptyFallback("Package")))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(application.date.nonEmptyFallback("—"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func compactField(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openPackageButton: some View {
        Button {
            openPackage()
        } label: {
            Label("Open Package", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .disabled(application.packageName.isEmpty)
        .help(application.packageName.isEmpty ? "No local package is available for this application." : "Open Package Detail")
    }
}

private struct StatusActionButtons: View {
    @EnvironmentObject private var store: DashboardStore
    var application: ApplicationRecord
    var controlSize: ControlSize = .small

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TrackerStatusQuickAction.allCases) { action in
                Button {
                    Task { await store.updateStatus(action, for: application) }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(controlSize)
                .disabled(store.isUpdatingStatus || application.packageName.isEmpty)
                .help(action.help)
            }
        }
    }
}

private struct ApplicationHealthStrip: View {
    var application: ApplicationRecord

    private var checks: [(label: String, isPassing: Bool)] {
        [
            ("Posting", application.health.hasPosting),
            ("Resume", application.health.hasResumeSource),
            ("PDF", application.files.contains { $0.format.lowercased() == "pdf" }),
            ("DOCX", application.files.contains { $0.format.lowercased() == "docx" }),
            (
                "Extraction",
                application.files.contains {
                    $0.relativePath.hasSuffix(".pdf.txt") || $0.relativePath.hasSuffix(".docx.txt")
                }
            ),
            ("ATS", application.health.atsFileCount > 0),
            ("Prep", application.health.hasInterviewPrep),
        ]
    }

    private var readyCount: Int {
        checks.filter(\.isPassing).count
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(checks, id: \.label) { check in
                Circle()
                    .fill(check.isPassing ? Color.green : Color.blue.opacity(0.14))
                    .overlay(
                        Circle()
                            .stroke(check.isPassing ? Color.green.opacity(0.35) : Color.blue.opacity(0.25), lineWidth: 1)
                    )
                    .frame(width: 9, height: 9)
                    .help("\(check.label): \(check.isPassing ? "ready" : "missing")")
            }
        }
        .accessibilityLabel("\(readyCount) of \(checks.count) package checks ready")
    }
}

private struct ApplicationsTableFooter: View {
    var shownCount: Int
    var filteredCount: Int
    var currentPage: Int
    var pageCount: Int
    var rowsPerPage: Int
    var goBack: () -> Void
    var goForward: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalFooter
            stackedFooter
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var horizontalFooter: some View {
        HStack(spacing: 14) {
            Text("Showing \(shownCount) of \(filteredCount) applications")
            Spacer()
            pagerControls
            Text("Rows per page: \(rowsPerPage)")
        }
    }

    private var stackedFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Showing \(shownCount) of \(filteredCount) applications")
            HStack {
                pagerControls
                Spacer()
                Text("Rows per page: \(rowsPerPage)")
            }
        }
    }

    private var pagerControls: some View {
        HStack(spacing: 12) {
            Button {
                goBack()
            } label: {
                Label("Previous page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPage == 0)
            .help("Previous page")

            Text("Page \(currentPage + 1) of \(pageCount)")
                .monospacedDigit()

            Button {
                goForward()
            } label: {
                Label("Next page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPage >= pageCount - 1)
            .help("Next page")
        }
    }
}
