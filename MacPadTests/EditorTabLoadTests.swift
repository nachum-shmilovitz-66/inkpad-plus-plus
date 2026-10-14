import XCTest
@testable import MacPad

/// MAC-49 regression: a file opened in a new tab showed line 2 at the top. The tab is loaded
/// before it is laid out, and SCI_GOTOPOS 0 on a view with no line on screen scrolled line 1 out.
final class EditorTabLoadTests: XCTestCase {
    private func longFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EditorTabLoadTests-\(UUID().uuidString).txt")
        try Data((1...100).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testALoadedFileStartsAtItsFirstLine() throws {
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(try longFile())
        XCTAssertEqual(tab.editor.send(SCI_GETFIRSTVISIBLELINE), 0)
        XCTAssertEqual(tab.editor.scrollView.contentView.bounds.minY, 0, "not scrolled by a pixel either")
        XCTAssertEqual(tab.caretPosition, 0)
        tab.detach()
    }

    func testAnOpenedFileShowsLineOneOnceLaidOut() throws {
        let window = MainWindowController()
        window.open(try longFile())
        window.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let tab = try XCTUnwrap(window.activeTab)
        XCTAssertEqual(tab.editor.send(SCI_GETFIRSTVISIBLELINE), 0)
        XCTAssertEqual(tab.editor.send(SCI_POINTYFROMPOSITION, 0, 0), 0, "line 1 is drawn at the top")
        window.openTabs.forEach { $0.detach() }
    }
}
