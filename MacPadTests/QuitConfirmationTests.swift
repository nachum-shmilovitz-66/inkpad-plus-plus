import XCTest
@testable import MacPad

/// MAC-74: closing the window asks about unsaved documents once; the quit that follows does not
/// ask again.
final class QuitConfirmationTests: XCTestCase {
    func testAnsweredClosePromptsAreNotAskedAgainOnQuit() throws {
        let window = MainWindowController()
        addTeardownBlock { window.openTabs.forEach { $0.detach() } }
        window.newDocument(nil)
        XCTAssertFalse(window.needsQuitConfirmation, "nothing unsaved, nothing to ask")
        try XCTUnwrap(window.activeTab).editor.send(SCI_APPENDTEXT, 1, string: "x")
        XCTAssertTrue(window.needsQuitConfirmation, "an unsaved edit: quitting asks")

        window.closeAfterConfirmation()  // the user answered the window's "Save file?" prompts
        XCTAssertFalse(window.needsQuitConfirmation, "the quit right after does not ask again")
        XCTAssertTrue(window.hasDirtyTabs, "the document was discarded, not saved")
    }

    func testAWindowShownAgainAsksAgain() throws {
        let window = MainWindowController()
        addTeardownBlock { window.openTabs.forEach { $0.detach() }; window.window?.orderOut(nil) }
        window.newDocument(nil)
        try XCTUnwrap(window.activeTab).editor.send(SCI_APPENDTEXT, 1, string: "x")
        window.closeAfterConfirmation()
        window.showWindow(nil)
        XCTAssertTrue(window.needsQuitConfirmation)
    }
}
