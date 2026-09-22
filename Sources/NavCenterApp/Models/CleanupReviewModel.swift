import Foundation
import NavCenterCore

struct CleanupReviewRow: Identifiable, Equatable {
    var id: String { packageName }
    let packageName: String
    let status: String
    let packageDate: String
    let isTracked: Bool
    let accessibilityLabel: String
}

enum CleanupReviewModel {
    static func rows(for preview: PackageCleanupPreview) -> [CleanupReviewRow] {
        preview.candidates.map { candidate in
            CleanupReviewRow(
                packageName: candidate.packageName,
                status: candidate.status,
                packageDate: candidate.packageDate,
                isTracked: candidate.isTracked,
                accessibilityLabel: "\(candidate.packageName), \(candidate.status), dated \(candidate.packageDate), \(candidate.isTracked ? "tracked" : "package only")"
            )
        }
    }
}

struct CleanupReviewRequest: Identifiable {
    let preview: PackageCleanupPreview
    var id: String { preview.fingerprint }
}
