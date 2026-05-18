import XCTest
@testable import NavCenterApp

final class MasterResumeLayoutTests: XCTestCase {
    func testEditorHeightLeavesRoomForFloatingChatLauncherInStandardWindow() {
        let editorHeight = MasterResumeEditorLayout.editorHeight(forViewportHeight: 620)

        XCTAssertLessThanOrEqual(editorHeight, 360)
        XCTAssertGreaterThanOrEqual(editorHeight, MasterResumeEditorLayout.minimumEditorHeight)
    }

    func testEditorHeightCapsOnTallWindows() {
        XCTAssertEqual(
            MasterResumeEditorLayout.editorHeight(forViewportHeight: 1_100),
            MasterResumeEditorLayout.maximumEditorHeight
        )
    }
}
