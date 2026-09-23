import Foundation
import SwiftUI

enum AccessibilityID {
    static let dashboardErrorOK = "dashboard.error.ok"
    static func sidebar(_ destination: DashboardDestination) -> String { "sidebar.\(destination.rawValue)" }
    static let toolbarSearch = "toolbar.search"
    static let toolbarRefresh = "toolbar.refresh"
    static let packageBack = "package.back"
    static func packageRail(_ action: PackageAction) -> String { "package.rail.\(action.rawValue)" }
    static let packageRailConfirm = "package.rail.confirm"
    static let packageRailCancel = "package.rail.cancel"
    static func packageStatus(_ action: TrackerStatusQuickAction) -> String { "package.status.\(action.rawValue)" }
    static func packageTab(_ key: String) -> String { "package.tab.\(key)" }
    static let packageReviewModePrimary = "package.review.mode.primary"
    static let packageReviewModeSecondary = "package.review.mode.secondary"
    static let packageInterviewPrepare = "package.interview.prepare"
    static let packageInterviewPrompt = "package.interview.prompt"
    static let packageInterviewApprove = "package.interview.approve"
    static let packageInterviewCancel = "package.interview.cancel"
    static let packageFilePreview = "package.file.preview"
    static let packageFileOpen = "package.file.open"
    static let packageFileReveal = "package.file.reveal"
    static func packageFilePreview(_ path: String) -> String { keyed(packageFilePreview, by: path) }
    static func packageFileOpen(_ path: String) -> String { keyed(packageFileOpen, by: path) }
    static func packageFileReveal(_ path: String) -> String { keyed(packageFileReveal, by: path) }
    static let packagePDFOpen = "package.pdf.open"
    static let statusHistoryList = "status.history.list"
    static let statusBannerDismiss = "status.banner.dismiss"
    static let noticeBannerDismiss = "notice.banner.dismiss"
    static let cleanupPreview = "cleanup.preview"
    static let cleanupRemove = "cleanup.remove"
    static let cleanupSheetConfirm = "cleanup.sheet.confirm"
    static let cleanupSheetCancel = "cleanup.sheet.cancel"
    static let codexLauncher = "codex.launcher"
    static let codexRefresh = "codex.refresh"
    static let codexClose = "codex.close"
    static let codexInput = "codex.input"
    static let codexSend = "codex.send"
    static let codexAllowEdits = "codex.allowEdits"
    static let codexConfirmEdits = "codex.confirmEdits"
    static let codexStop = "codex.stop"
    static let codexSignIn = "codex.signIn"
    static let codexCode = "codex.code"
    static let codexLoginOpen = "codex.login.open"
    static let settingsRefresh = "settings.refresh"
    static let settingsRecheckTools = "settings.recheckTools"
    static let intakeCompany = "intake.company"
    static let intakeRole = "intake.role"
    static let intakeSourceURL = "intake.sourceURL"
    static let intakeLocation = "intake.location"
    static let intakeSalary = "intake.salary"
    static let intakePosting = "intake.posting"
    static let intakeAutomation = "intake.automation"
    static let intakeApproveEdits = "intake.approveEdits"
    static let intakeCreate = "intake.create"
    static let intakeImport = "intake.import"
    static let intakeCodexSignIn = "intake.codex.signIn"
    static let intakeCodexLoginOpen = "intake.codex.login.open"
    static let intakeRefreshCodex = "intake.refreshCodex"
    static let resumeEditor = "resume.editor"
    static let resumeSave = "resume.save"
    static let resumeReload = "resume.reload"
    static let resumeDiscard = "resume.discard"
    static let resumeCancel = "resume.cancel"
    static let applicationsSearch = "applications.search"
    static let applicationsOpen = "applications.open"
    static func applicationsOpen(_ packageName: String) -> String { keyed(applicationsOpen, by: packageName) }
    static let applicationsPagePrevious = "applications.page.previous"
    static let applicationsPageNext = "applications.page.next"
    static func applicationsStatus(_ action: TrackerStatusQuickAction) -> String { "applications.status.\(action.rawValue)" }
    static func applicationsStatus(_ action: TrackerStatusQuickAction, packageName: String) -> String {
        keyed(applicationsStatus(action), by: packageName)
    }
    static func keyed(_ prefix: String, by key: String) -> String {
        let sanitized = String(key.unicodeScalars.map { scalar in
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) || scalar.value == 45
                ? Character(scalar) : "-"
        })
        return "\(prefix).\(sanitized.isEmpty ? "-" : sanitized)"
    }
    static func applicationsFilter(_ title: String) -> String {
        "applications.filter.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }
    static func applicationsFilterOption(_ title: String, option: String) -> String {
        let encoded = option.utf8.map { String(format: "%02x", $0) }.joined()
        return "\(applicationsFilter(title)).\(encoded.isEmpty ? "0" : encoded)"
    }

    static var registered: [String] {
        let controls: [String] = [dashboardErrorOK, toolbarSearch, toolbarRefresh, packageBack, packageRailConfirm, packageRailCancel,
         packageReviewModePrimary, packageReviewModeSecondary, packageInterviewPrepare, packageInterviewPrompt, packageInterviewApprove,
         packageInterviewCancel, packageFilePreview, packageFileOpen, packageFileReveal, packagePDFOpen,
         statusHistoryList, statusBannerDismiss, noticeBannerDismiss, cleanupPreview, cleanupRemove, cleanupSheetConfirm,
         cleanupSheetCancel, codexLauncher, codexRefresh, codexClose, codexInput, codexSend,
         codexAllowEdits, codexConfirmEdits, codexStop, codexSignIn, codexCode, codexLoginOpen,
         settingsRefresh, settingsRecheckTools, intakeCompany, intakeRole, intakeSourceURL,
         intakeLocation, intakeSalary, intakePosting, intakeAutomation, intakeApproveEdits,
         intakeCreate, intakeImport, intakeCodexSignIn, intakeCodexLoginOpen, intakeRefreshCodex, resumeEditor,
         resumeSave, resumeReload, resumeDiscard, resumeCancel, applicationsSearch,
         applicationsOpen, applicationsPagePrevious, applicationsPageNext]
        let navigation = DashboardDestination.allCases.map(sidebar)
        let rail = PackageAction.railActions.map(packageRail)
        let status = TrackerStatusQuickAction.allCases.map(packageStatus)
        let applicationStatus = TrackerStatusQuickAction.allCases.map(applicationsStatus)
        let tabs = PackageTabKey.allCases.map { packageTab($0.rawValue) } + [packageTab("selection")]
        let filters = ["Status", "Location", "Source"].map(applicationsFilter)
        return controls + navigation + rail + status + applicationStatus + tabs + filters
    }
}

enum LayoutMetrics {
    static let minimumWindowSize = CGSize(width: 820, height: 620)
    static let detailChromeHeight: CGFloat = 330
    static func reviewPaneMinimumHeight(fillingAvailableHeight: Bool) -> CGFloat {
        fillingAvailableHeight ? 280 : 480
    }
    static func codexPanelHeight(forWindowHeight height: CGFloat) -> CGFloat {
        min(560, max(320, height - 124))
    }
}

enum KeyboardShortcutRegistry {
    struct Entry {
        let identifier: String
        let key: String
        let modifiers: EventModifiers
        let title: String
    }

    static let destinations: [Entry] = DashboardDestination.allCases.enumerated().map { index, destination in
        Entry(identifier: AccessibilityID.sidebar(destination), key: String(index + 1), modifiers: .command, title: destination.title)
    }
    static let back = Entry(identifier: AccessibilityID.packageBack, key: "[", modifiers: .command, title: "Back to List")
    static let find = Entry(identifier: AccessibilityID.toolbarSearch, key: "f", modifiers: [.command, .shift], title: "Search Applications")
    static let codex = Entry(identifier: AccessibilityID.codexLauncher, key: "c", modifiers: [.command, .shift], title: "Toggle Codex Panel")
    static let ats = Entry(identifier: AccessibilityID.packageRail(.atsScan), key: "a", modifiers: [.command, .shift], title: "Run ATS Scan…")
    static let export = Entry(identifier: AccessibilityID.packageRail(.exportArtifacts), key: "e", modifiers: [.command, .shift], title: "Export Artifacts…")
    static let settings = Entry(identifier: AccessibilityID.sidebar(.settings), key: ",", modifiers: .command, title: "Settings…")
    static let refresh = Entry(identifier: AccessibilityID.toolbarRefresh, key: "r", modifiers: .command, title: "Refresh Dashboard")
    static var registered: [Entry] { destinations + [back, find, codex, ats, export, settings, refresh] }
}
