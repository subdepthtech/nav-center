import Foundation
import NavCenterCore

enum TrackerStatusQuickAction: String, CaseIterable, Identifiable {
    case submitted
    case interview
    case notPursuing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .submitted: return "Applied"
        case .interview: return "Interview"
        case .notPursuing: return "Skip"
        }
    }

    var help: String {
        switch self {
        case .submitted: return "Mark applied"
        case .interview: return "Mark interview"
        case .notPursuing: return "Mark not pursuing"
        }
    }

    var systemImage: String {
        switch self {
        case .submitted: return "paperplane"
        case .interview: return "person.2"
        case .notPursuing: return "xmark.circle"
        }
    }

    var trackerStatus: TrackerStatus {
        switch self {
        case .submitted: return .submitted
        case .interview: return .interview
        case .notPursuing: return .notPursuing
        }
    }
}
