import XCTest
@testable import Inkpad

/// MAC-45: the Document Map.
final class DocumentMapTests: XCTestCase {
    private func longText() -> Data { Data((1...400).map { "line \($0)" }.joined(separator: "\n").utf8) }

    func testTheMapSharesTheDocumentAndIsZoomedOut() {
        let window = MainWindowController()
        let tab = window.newTab()
        tab.editor.setUTF8Bytes(longText())
        window.setDocumentMapVisible(true)
        let map = window.documentMap.map
        XCTAssertEqual(map.send(SCI_GETDOCPOINTER), tab.editor.send(SCI_GETDOCPOINTER), "one document, two views")
        XCTAssertEqual(map.send(SCI_GETZOOM), -10)
        tab.editor.send(SCI_APPENDTEXT, 6, string: "\nadded")
        XCTAssertEqual(map.send(SCI_GETLENGTH), tab.editor.send(SCI_GETLENGTH), "edits show in the map at once")
        window.setDocumentMapVisible(false)
        XCTAssertNotEqual(map.send(SCI_GETDOCPOINTER), tab.editor.send(SCI_GETDOCPOINTER), "a closed map lets the document go")
        window.openTabs.forEach { $0.detach() }
    }

    func testTheBandFollowsTheEditorAndMovesIt() {
        let window = MainWindowController()
        let tab = window.newTab()
        tab.editor.setUTF8Bytes(longText())
        window.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.setDocumentMapVisible(true)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let panel = window.documentMap
        panel.sync()
        let firstBand = panel.zone.band
        XCTAssertGreaterThan(firstBand.height, 0)
        tab.editor.send(SCI_SETFIRSTVISIBLELINE, 200)
        panel.sync()
        XCTAssertNotEqual(panel.zone.band.minY, firstBand.minY, "the band moves with the editor")
        panel.moveEditor(toMapY: 0)
        XCTAssertLessThan(tab.editor.send(SCI_GETFIRSTVISIBLELINE), 200, "clicking the map's top scrolls the editor up")
        let before = tab.editor.send(SCI_GETFIRSTVISIBLELINE)
        panel.scrollEditor(by: -1)
        XCTAssertGreaterThan(tab.editor.send(SCI_GETFIRSTVISIBLELINE), before, "the wheel scrolls the editor")
        window.setDocumentMapVisible(false)
        window.openTabs.forEach { $0.detach() }
    }

    func testTheMapFollowsTheVisibleTab() {
        let window = MainWindowController()
        let first = window.newTab()
        first.editor.setUTF8Bytes(Data("one".utf8))
        let second = window.newTab()
        second.editor.setUTF8Bytes(Data("two".utf8))
        window.setDocumentMapVisible(true)
        XCTAssertEqual(window.documentMap.map.send(SCI_GETDOCPOINTER), second.editor.send(SCI_GETDOCPOINTER))
        window.selectTab(at: 0)
        XCTAssertEqual(window.documentMap.map.send(SCI_GETDOCPOINTER), first.editor.send(SCI_GETDOCPOINTER))
        window.setDocumentMapVisible(false)
        window.openTabs.forEach { $0.detach() }
    }
}
