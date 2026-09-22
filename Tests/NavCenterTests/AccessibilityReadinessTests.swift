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

    func testKeyboardShortcutsAreUniqueAndAvoidReservedSystemKeys() {
        let shortcuts = KeyboardShortcutRegistry.registered
        let combinations = shortcuts.map { "\($0.modifiers.rawValue):\($0.key.lowercased())" }
        XCTAssertEqual(Set(combinations).count, combinations.count)
        let reserved: Set<String> = ["q", "w", "h", "m", "n", "o", "p", "s", "z", "x", "c", "v", "a", "`", "tab"]
        for shortcut in shortcuts where shortcut.modifiers == .command {
            XCTAssertFalse(reserved.contains(shortcut.key.lowercased()), shortcut.title)
        }
        XCTAssertEqual(shortcuts.filter { $0.key == "," }.map(\.title), ["Settings…"])
        XCTAssertTrue(shortcuts.allSatisfy { !$0.identifier.hasPrefix("package.status.") && !$0.identifier.hasPrefix("applications.status.") })
    }

    func testReviewWorkspaceMinimumHeightFitsMinimumWindow() {
        XCTAssertLessThan(LayoutMetrics.reviewPaneMinimumHeight, LayoutMetrics.minimumWindowSize.height)
    }

    func testCodexPanelFitsMinimumWindow() {
        let height = LayoutMetrics.codexPanelHeight(forWindowHeight: LayoutMetrics.minimumWindowSize.height)
        XCTAssertLessThanOrEqual(height + 124, LayoutMetrics.minimumWindowSize.height)
        XCTAssertGreaterThanOrEqual(height, 320)
    }
}
