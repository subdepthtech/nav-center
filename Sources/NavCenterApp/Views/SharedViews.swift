import SwiftUI

struct HeaderBlock: View {
    var title: String
    var subtitle: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                headerText
                Spacer(minLength: 16)
                LocalOnlyPill()
            }

            VStack(alignment: .leading, spacing: 10) {
                headerText
                LocalOnlyPill()
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LocalOnlyPill: View {
    var body: some View {
        Label("Local-only", systemImage: "lock")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.blue.opacity(0.10), in: Capsule())
            .accessibilityLabel("Local-only private dashboard")
    }
}

struct StatCard: View {
    var title: String
    var value: Int
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
            Text("\(value)")
                .font(.system(size: 30, weight: .semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Panel<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusBadge: View {
    private let status: String

    init(_ status: String) {
        self.status = status.isEmpty ? "Unknown" : status
    }

    var body: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private var color: Color {
        let normalized = status.lowercased()
        if normalized.contains("submitted") { return .green }
        if normalized.contains("interview") { return .purple }
        if normalized.contains("generated") { return .blue }
        if normalized.contains("sourced") || normalized.contains("pursue") { return .blue }
        if normalized.contains("package") { return .orange }
        return .secondary
    }
}

struct HealthRow: View {
    var label: String
    var isPassing: Bool

    var body: some View {
        HStack {
            Image(systemName: isPassing ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isPassing ? .green : .secondary)
            Text(label)
            Spacer()
        }
        .font(.callout)
    }
}

struct StatusDot: View {
    var status: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status.lowercased() {
        case "succeeded": return .green
        case "failed": return .red
        case "blocked": return .orange
        case "running": return .blue
        default: return .secondary
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding()
    }
}

struct ItemList<Item: Identifiable, Row: View>: View {
    var items: [Item]
    var emptyMessage: String
    var row: (Item) -> Row

    var body: some View {
        if items.isEmpty {
            EmptyStateView(title: "Nothing queued", message: emptyMessage)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

struct ApplicationCompactRow: View {
    var application: ApplicationSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                icon
                textBlock
                Spacer()
                StatusBadge(application.status)
            }

            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 8) {
                    textBlock
                    StatusBadge(application.status)
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: "briefcase")
            .foregroundStyle(.blue)
            .frame(width: 18)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(application.company.nonEmptyFallback("Untracked package"))
                .fontWeight(.medium)
                .lineLimit(1)
            Text(application.role.nonEmptyFallback(application.packageName))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !application.nextActionDate.isEmpty {
                Text("Next: \(application.nextActionDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension String {
    func nonEmptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
