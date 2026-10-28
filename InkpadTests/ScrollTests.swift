import XCTest
@testable import Inkpad

/// Scrolling a large document keeps scrolling: every wheel turn moves the view on.
final class ScrollTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ScrollTests-\(UUID().uuidString).json")
        var text = "[\n"
        for i in 0..<560 {
            text += "    {\n        \"ruleId\": \(300 + i),\n        \"deviceTypes\": [\n            \"OnePiece\"\n        ],\n"
            text += "        \"endpoint\": null,\n        \"enabled\": \(i % 2 == 0),\n        \"notes\": \"GAP: no event mapped\"\n    },\n"
        }
        text += "    {}\n]\n"
        try Data(text.utf8).write(to: file)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: file) }

    private func wheel(_ lines: Int32) -> NSEvent {
        NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!)!
    }

    func testEveryWheelTurnScrollsFurther() throws {
        let window = MainWindowController()
        addTeardownBlock { window.openTabs.forEach { $0.detach() }; window.window?.orderOut(nil) }
        window.showWindow(nil)
        window.open(file)
        let editor = try XCTUnwrap(window.activeTab).editor
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var firstLines = [editor.send(SCI_GETFIRSTVISIBLELINE)]
        for _ in 0..<4 {
            editor.scrollView.scrollWheel(with: wheel(-10))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            firstLines.append(editor.send(SCI_GETFIRSTVISIBLELINE))
        }
        print("first visible lines:", firstLines)
        for (a, b) in zip(firstLines, firstLines.dropFirst()) {
            XCTAssertGreaterThan(b, a, "each wheel turn scrolls further: \(firstLines)")
        }
    }

    /// One trackpad swipe: precise (pixel) deltas in phases, then momentum, as a real gesture sends.
    private func swipe(_ view: NSScrollView, dy: Int32, dx: Int32 = 0) {
        func event(_ dy: Int32, _ dx: Int32, phase: Int64, momentum: Int64) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return NSEvent(cgEvent: cg)!
        }
        let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4
        view.scrollWheel(with: event(dy, dx, phase: began, momentum: 0))
        for _ in 0..<6 { view.scrollWheel(with: event(dy, dx, phase: changed, momentum: 0)); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.scrollWheel(with: event(0, 0, phase: ended, momentum: 0))
        view.scrollWheel(with: event(dy, dx, phase: 0, momentum: began))
        for _ in 0..<4 { view.scrollWheel(with: event(dy / 2, 0, phase: 0, momentum: changed)); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.scrollWheel(with: event(0, 0, phase: 0, momentum: 3))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testEveryTrackpadSwipeScrollsFurther() throws {
        let window = MainWindowController()
        addTeardownBlock { window.openTabs.forEach { $0.detach() }; window.window?.orderOut(nil) }
        window.showWindow(nil)
        window.open(file)
        let editor = try XCTUnwrap(window.activeTab).editor
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var firstLines = [editor.send(SCI_GETFIRSTVISIBLELINE)]
        var xOffsets = [editor.send(SCI_GETXOFFSET)]
        for _ in 0..<4 {
            swipe(editor.scrollView, dy: -40, dx: -3)
            firstLines.append(editor.send(SCI_GETFIRSTVISIBLELINE))
            xOffsets.append(editor.send(SCI_GETXOFFSET))
        }
        print("swipe first visible lines:", firstLines, "x offsets:", xOffsets,
              "clip origin:", editor.scrollView.contentView.bounds.origin)
        for (a, b) in zip(firstLines, firstLines.dropFirst()) {
            XCTAssertGreaterThan(b, a, "each swipe scrolls further: \(firstLines)")
        }
    }

    /// Regression (MAC-79): every scroll step used to refresh the whole window (tab bar, title,
    /// panels, status bar), relaying it out in the middle of a trackpad gesture.
    func testScrollingDoesNotRefreshTheWindow() throws {
        let window = MainWindowController()
        addTeardownBlock { window.openTabs.forEach { $0.detach() }; window.window?.orderOut(nil) }
        window.showWindow(nil)
        window.open(file)
        let tab = try XCTUnwrap(window.activeTab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var refreshes = 0
        let original = tab.onChange
        tab.onChange = { refreshes += 1; original?() }
        for _ in 0..<3 { swipe(tab.editor.scrollView, dy: -40) }
        XCTAssertGreaterThan(tab.editor.send(SCI_GETFIRSTVISIBLELINE), 0, "it scrolled")
        XCTAssertEqual(refreshes, 0, "a scroll changes nothing around the editor")

        tab.editor.send(SCI_GOTOLINE, 10)  // moving the caret still refreshes (status bar)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(refreshes, 0)
    }
}
