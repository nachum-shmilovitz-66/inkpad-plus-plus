import XCTest
@testable import MacPad

/// MAC-26: where the main window opens.
final class WindowPlacementTests: XCTestCase {
    private let macBook = NSRect(x: 0, y: 0, width: 1512, height: 944)  // a 14" MacBook's visible area

    // MARK: First launch

    func testFirstLaunchIsCenteredHorizontallyAndSlightlyAboveTheMiddle() {
        let f = WindowPlacement.defaultFrame(in: macBook)
        XCTAssertEqual(f.midX, macBook.midX, accuracy: 1)
        let below = f.minY - macBook.minY, above = macBook.maxY - f.maxY
        XCTAssertGreaterThan(below, above, "a little above center, like NSWindow.center()")
        XCTAssertTrue(macBook.contains(f))
    }

    func testNotInTheBottomLeftCorner() {
        let f = WindowPlacement.defaultFrame(in: macBook)
        XCTAssertGreaterThan(f.minX, 100)
        XCTAssertGreaterThan(f.minY, 50)
    }

    func testSizeSuitsTheScreen() {
        let laptop = WindowPlacement.defaultFrame(in: macBook)
        XCTAssertEqual(laptop.width, 907, accuracy: 1)   // 60% of 1512
        XCTAssertEqual(laptop.height, 755, accuracy: 1)  // 80% of 944

        let small = WindowPlacement.defaultFrame(in: NSRect(x: 0, y: 0, width: 1024, height: 700))
        XCTAssertEqual(small.width, 900)   // never below 900 when the screen allows
        XCTAssertEqual(small.height, 600)

        let big = WindowPlacement.defaultFrame(in: NSRect(x: 0, y: 0, width: 5120, height: 2800))
        XCTAssertEqual(big.width, 3072)
        XCTAssertEqual(big.height, 2240)
    }

    func testAScreenWithAMenuBarOffsetIsRespected() {
        let visible = NSRect(x: 1512, y: 25, width: 1920, height: 1055)  // a second display to the right
        let f = WindowPlacement.defaultFrame(in: visible)
        XCTAssertTrue(visible.contains(f))
        XCTAssertEqual(f.midX, visible.midX, accuracy: 1)
    }

    // MARK: Later launches

    func testASavedFrameOnScreenIsKept() {
        let saved = NSRect(x: 300, y: 150, width: 1000, height: 700)
        XCTAssertEqual(WindowPlacement.frame(saved: saved, screens: [macBook], main: macBook), saved)
    }

    func testASavedFrameOnASecondDisplayIsKept() {
        let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
        let saved = NSRect(x: 2000, y: 300, width: 1200, height: 800)
        XCTAssertEqual(WindowPlacement.frame(saved: saved, screens: [macBook, external], main: macBook), saved)
    }

    func testASavedFrameOnADisconnectedDisplayFallsBackToTheDefault() {
        let saved = NSRect(x: 2000, y: 300, width: 1200, height: 800)  // that display is gone
        XCTAssertEqual(WindowPlacement.frame(saved: saved, screens: [macBook], main: macBook),
                       WindowPlacement.defaultFrame(in: macBook))
    }

    func testATitleBarPushedOffTheTopFallsBackToTheDefault() {
        let saved = NSRect(x: 300, y: 1000, width: 900, height: 600)  // title bar above the screen
        XCTAssertEqual(WindowPlacement.frame(saved: saved, screens: [macBook], main: macBook),
                       WindowPlacement.defaultFrame(in: macBook))
    }

    func testNoSavedFrameOrATinyOneUsesTheDefault() {
        XCTAssertEqual(WindowPlacement.frame(saved: nil, screens: [macBook], main: macBook),
                       WindowPlacement.defaultFrame(in: macBook))
        XCTAssertEqual(WindowPlacement.frame(saved: NSRect(x: 10, y: 10, width: 50, height: 40), screens: [macBook], main: macBook),
                       WindowPlacement.defaultFrame(in: macBook))
    }

    // MARK: AppKit's saved form

    func testParsingAppKitsSavedFrame() {
        XCTAssertEqual(WindowPlacement.savedFrame(from: "302 113 907 755 0 0 1512 944 "),
                       NSRect(x: 302, y: 113, width: 907, height: 755))
        XCTAssertNil(WindowPlacement.savedFrame(from: nil))
        XCTAssertNil(WindowPlacement.savedFrame(from: "garbage"))
        XCTAssertNil(WindowPlacement.savedFrame(from: "1 2 3"))
    }

    // MARK: The real main window (in the test host)

    func testTheMainWindowOpensAtTheDefaultAndTheTestHostSavesNothing() throws {
        let window = try XCTUnwrap(AppDelegate.shared.mainWindow.window)
        XCTAssertEqual(window.frameAutosaveName, "", "the test host must not overwrite the user's window position")
        XCTAssertGreaterThan(window.frame.minX, 50, "not in the bottom-left corner")
        XCTAssertEqual(window.contentMinSize, WindowPlacement.minimumSize)
    }
}
