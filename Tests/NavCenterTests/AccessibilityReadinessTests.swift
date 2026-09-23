import XCTest
import SwiftUI
@testable import NavCenterApp

final class AccessibilityReadinessTests: XCTestCase {
    func testEveryDestinationHasTitleSystemImageShortcutAndIdentifier() {
        XCTAssertEqual(DashboardDestination.allCases.count, 7)
        for (index, destination) in DashboardDestination.allCases.enumerated() {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.systemImage.isEmpty)
            XCTAssertEqual(KeyboardShortcutRegistry.destinations[index].key, String(index + 1))
            XCTAssertEqual(KeyboardShortcutRegistry.destinations[index].title, destination.title)
            XCTAssertEqual(KeyboardShortcutRegistry.destinations[index].identifier, AccessibilityID.sidebar(destination))
        }
    }

    func testRailAndStatusActionsExposeUniqueIdentifiersAndNonEmptyLabelsAndHelp() {
        let rail = PackageAction.railActions.map { (AccessibilityID.packageRail($0), $0.title, $0.confirmationTitle) }
        let status = TrackerStatusQuickAction.allCases.map { (AccessibilityID.packageStatus($0), $0.title, $0.help) }
        XCTAssertEqual(Set((rail + status).map(\.0)).count, rail.count + status.count)
        for (_, label, help) in rail + status {
            XCTAssertFalse(label.isEmpty)
            XCTAssertFalse(help.isEmpty)
        }
    }

    func testAccessibilityIdentifierRegistryIsUniqueAndNamespaced() throws {
        let identifiers = AccessibilityID.registered
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        let expression = try NSRegularExpression(pattern: "^[a-z]+(\\.[A-Za-z0-9-]+)+$")
        for identifier in identifiers {
            let range = NSRange(identifier.startIndex..<identifier.endIndex, in: identifier)
            XCTAssertNotNil(expression.firstMatch(in: identifier, range: range), identifier)
        }
    }

    func testKeyedIdentifiersSanitizeAndStayNamespaced() {
        XCTAssertEqual(AccessibilityID.applicationsOpen("Acme/Role_1"), "applications.open.Acme-Role-1")
        XCTAssertEqual(AccessibilityID.applicationsStatus(.allCases[0], packageName: "A B"),
                       "\(AccessibilityID.applicationsStatus(.allCases[0])).A-B")
        XCTAssertEqual(AccessibilityID.packageFilePreview("artifacts/Resume_1.pdf"),
                       "package.file.preview.artifacts-Resume-1-pdf")
        XCTAssertEqual(AccessibilityID.packageFileOpen("a/b"), "package.file.open.a-b")
        XCTAssertEqual(AccessibilityID.packageFileReveal("a/b"), "package.file.reveal.a-b")
    }

    func testKeyboardShortcutsAreUniqueAndAvoidReservedSystemKeys() {
        let shortcuts = KeyboardShortcutRegistry.registered
        let combinations = shortcuts.map { "\($0.modifiers.rawValue):\($0.key.lowercased())" }
        XCTAssertEqual(Set(combinations).count, combinations.count)
        let reserved: [(KeyEquivalent, EventModifiers)] =
            ["q", "w", "h", "m", "n", "o", "p", "s", "z", "x", "c", "v", "a", "`"].map {
                (KeyEquivalent($0.first!), .command)
            } + [(.tab, .command)]
        for shortcut in shortcuts {
            XCTAssertFalse(reserved.contains { key, modifiers in
                key == KeyEquivalent(shortcut.key.lowercased().first!) && modifiers == shortcut.modifiers
            }, shortcut.title)
        }
        XCTAssertEqual(shortcuts.filter { $0.key == "," }.map(\.title), ["Settings…"])
        let trackerTitles = Set(TrackerStatusQuickAction.allCases.map(\.title))
        XCTAssertTrue(shortcuts.allSatisfy { !trackerTitles.contains($0.title) })
    }

    func testReviewWorkspaceMinimumHeightFitsMinimumWindow() {
        XCTAssertGreaterThanOrEqual(LayoutMetrics.minimumWindowSize.height - LayoutMetrics.detailChromeHeight,
                                    LayoutMetrics.reviewPaneMinimumHeight(fillingAvailableHeight: true))
        XCTAssertEqual(LayoutMetrics.reviewPaneMinimumHeight(fillingAvailableHeight: false), 480)
    }

    func testCodexPanelFitsMinimumWindow() {
        let height = LayoutMetrics.codexPanelHeight(forWindowHeight: LayoutMetrics.minimumWindowSize.height)
        XCTAssertLessThanOrEqual(height + 58 + 12 + 44, LayoutMetrics.minimumWindowSize.height)
        XCTAssertGreaterThanOrEqual(height, 320)
    }
}
