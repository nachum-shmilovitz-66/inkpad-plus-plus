import XCTest
@testable import MacPad

/// Tab order and selection. The behaviour mirrors Notepad++: a new tab becomes active, closing
/// the active tab moves right (or left at the end), and next/previous wrap.
final class TabListTests: XCTestCase {
    private func list(_ names: String...) -> TabList<String> {
        var list = TabList<String>()
        names.forEach { list.append($0) }
        return list
    }

    func testEmptyListHasNoActiveDocument() {
        let list = TabList<String>()
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.activeIndex)
        XCTAssertNil(list.active)
    }

    func testAppendActivatesTheNewTab() {
        var list = TabList<String>()
        XCTAssertEqual(list.append("a"), 0)
        XCTAssertEqual(list.append("b"), 1)
        XCTAssertEqual(list.active, "b")
        XCTAssertEqual(list.count, 2)
    }

    func testInsertActivatesTheInsertedTab() {
        var list = list("a", "b", "c")
        list.insert("x", at: 1)
        XCTAssertEqual(list.items, ["a", "x", "b", "c"])
        XCTAssertEqual(list.active, "x")
    }

    func testInsertClampsOutOfRangeIndices() {
        var list = list("a")
        list.insert("first", at: -5)
        list.insert("last", at: 99)
        XCTAssertEqual(list.items, ["first", "a", "last"])
    }

    // MARK: closing

    func testClosingTheActiveTabActivatesTheOneToTheRight() {
        var list = list("a", "b", "c")
        list.select(1)
        XCTAssertEqual(list.remove(at: 1), "b")
        XCTAssertEqual(list.active, "c")
    }

    func testClosingTheLastTabActivatesTheOneToTheLeft() {
        var list = list("a", "b", "c")   // "c" is active after the appends
        XCTAssertEqual(list.remove(at: 2), "c")
        XCTAssertEqual(list.active, "b")
    }

    func testClosingATabLeftOfTheActiveOneKeepsItActive() {
        var list = list("a", "b", "c")
        list.select(2)
        list.remove(at: 0)
        XCTAssertEqual(list.active, "c", "the same document must stay active")
        XCTAssertEqual(list.activeIndex, 1, "its index shifted down by one")
    }

    func testClosingATabRightOfTheActiveOneKeepsIndexAndDocument() {
        var list = list("a", "b", "c")
        list.select(0)
        list.remove(at: 2)
        XCTAssertEqual(list.activeIndex, 0)
        XCTAssertEqual(list.active, "a")
    }

    func testClosingTheOnlyTabLeavesNothingActive() {
        var list = list("a")
        list.remove(at: 0)
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.activeIndex)
        XCTAssertNil(list.active)
    }

    // MARK: next / previous

    func testNextAndPreviousWrapAround() {
        var list = list("a", "b", "c")
        list.select(0)
        list.selectNext()
        XCTAssertEqual(list.active, "b")
        list.selectNext()
        list.selectNext()
        XCTAssertEqual(list.active, "a", "wrapped past the end")
        list.selectPrevious()
        XCTAssertEqual(list.active, "c", "wrapped past the start")
    }

    func testNextAndPreviousOnAnEmptyListDoNothing() {
        var list = TabList<String>()
        list.selectNext()
        list.selectPrevious()
        XCTAssertNil(list.activeIndex)
    }

    func testSelectIgnoresOutOfRangeIndices() {
        var list = list("a", "b")
        list.select(0)
        list.select(7)
        list.select(-1)
        XCTAssertEqual(list.activeIndex, 0)
    }

    // MARK: reordering

    func testMovingTheActiveTabKeepsItActive() {
        var list = list("a", "b", "c")
        list.select(0)
        list.move(from: 0, to: 2)
        XCTAssertEqual(list.items, ["b", "c", "a"])
        XCTAssertEqual(list.active, "a")
        XCTAssertEqual(list.activeIndex, 2)
    }

    func testMovingAnotherTabPastTheActiveOneTracksTheActiveDocument() {
        var list = list("a", "b", "c")
        list.select(1)                 // "b"
        list.move(from: 0, to: 2)      // "a" moves to the end
        XCTAssertEqual(list.items, ["b", "c", "a"])
        XCTAssertEqual(list.active, "b", "the active document must not change")

        list = self.list("a", "b", "c")
        list.select(1)                 // "b"
        list.move(from: 2, to: 0)      // "c" moves to the front
        XCTAssertEqual(list.items, ["c", "a", "b"])
        XCTAssertEqual(list.active, "b")
    }

    func testMoveIgnoresNoOpAndInvalidSources() {
        var list = list("a", "b")
        list.move(from: 1, to: 1)
        list.move(from: 5, to: 0)
        XCTAssertEqual(list.items, ["a", "b"])
    }

    func testFirstIndexFindsAnOpenDocument() {
        let list = list("a", "b")
        XCTAssertEqual(list.firstIndex { $0 == "b" }, 1)
        XCTAssertNil(list.firstIndex { $0 == "zzz" })
    }
}

/// Tab and window labels.
final class TabTitleTests: XCTestCase {
    func testUnsavedDocumentsAreNamedNewN() {
        XCTAssertEqual(TabTitle.displayName(url: nil, untitledNumber: 1), "new 1")
        XCTAssertEqual(TabTitle.displayName(url: nil, untitledNumber: 12), "new 12")
    }

    func testSavedDocumentsShowTheFileNameOnly() {
        XCTAssertEqual(
            TabTitle.displayName(url: URL(fileURLWithPath: "/tmp/deep/path/notes.txt"), untitledNumber: 3),
            "notes.txt")
    }

    func testModifiedDocumentsAreMarkedOnTheTab() {
        XCTAssertEqual(TabTitle.tabLabel(displayName: "notes.txt", isModified: false), "notes.txt")
        XCTAssertEqual(TabTitle.tabLabel(displayName: "notes.txt", isModified: true), "• notes.txt")
    }
}
