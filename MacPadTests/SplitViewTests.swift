import XCTest
@testable import MacPad

/// MAC-47: Notepad++'s two views — Move / Clone to Other View, focus, synchronized scrolling and
/// the session.
final class SplitViewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SplitViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ text: String = "hello") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ tab: EditorTab) -> String { String(decoding: tab.editor.utf8Bytes(), as: UTF8.self) }
    private func names(_ window: MainWindowController, _ view: Int) -> [String] { window.panes[view].tabs.items.map(\.displayName) }
    private func close(_ window: MainWindowController) { window.openTabs.forEach { $0.detach() } }

    /// Opens `url` and clones it into the other view; returns (original, clone).
    private func cloned(_ window: MainWindowController, _ url: URL) throws -> (EditorTab, EditorTab) {
        window.open(url)
        let original = try XCTUnwrap(window.activeTab)
        window.cloneToOtherView(nil)
        return (original, try XCTUnwrap(window.activeTab))
    }

    // MARK: - Clone to Other View

    func testACloneIsASecondViewOfTheSameDocument() throws {
        let window = MainWindowController()
        let (original, clone) = try cloned(window, try file("a.txt"))
        XCTAssertFalse(clone === original)
        XCTAssertEqual(window.activeView, 1, "the clone has the focus")
        XCTAssertTrue(window.isOtherViewVisible)
        XCTAssertTrue(clone.isClone)
        XCTAssertFalse(original.isClone)
        XCTAssertTrue(clone.twin === original && original.twin === clone)
        XCTAssertTrue(clone.documentOwner === original)
        XCTAssertEqual(clone.editor.send(SCI_GETDOCPOINTER), original.editor.send(SCI_GETDOCPOINTER))
        XCTAssertEqual(clone.displayName, "a.txt")

        clone.editor.send(SCI_APPENDTEXT, 6, string: " world")
        XCTAssertEqual(text(original), "hello world", "an edit in one view is in both")
        XCTAssertTrue(original.isModified)
        XCTAssertTrue(clone.isModified)
        clone.editor.send(SCI_UNDO)
        XCTAssertEqual(text(original), "hello", "one undo history")
        close(window)
    }

    func testACloneCountsAsOneDocument() throws {
        let window = MainWindowController()
        _ = try cloned(window, try file("a.txt"))
        XCTAssertEqual(window.openTabs.count, 2)
        XCTAssertEqual(window.openDocuments.count, 1)
        XCTAssertEqual(window.searchDocuments.count, 1, "Find in all opened documents searches it once")
        XCTAssertEqual(window.clipboardText(for: 3), "a.txt\r\n", "Copy All Filenames names it once")
        close(window)
    }

    func testCloningAgainFocusesTheExistingClone() throws {
        let window = MainWindowController()
        let (original, clone) = try cloned(window, try file("a.txt"))
        window.selectTab(at: 0, inView: 0)
        XCTAssertTrue(window.activeTab === original)
        window.cloneToOtherView(nil)
        XCTAssertEqual(window.openTabs.count, 2, "no third copy")
        XCTAssertTrue(window.activeTab === clone)
        close(window)
    }

    func testSavingFromTheCloneWritesTheDocument() throws {
        let window = MainWindowController()
        let url = try file("a.txt")
        let (original, clone) = try cloned(window, url)
        clone.editor.send(SCI_APPENDTEXT, 1, string: "!")
        var saved = false
        clone.save { saved = $0 }
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello!")
        XCTAssertFalse(original.isModified)
        XCTAssertFalse(clone.isModified)
        close(window)
    }

    func testTheFileStateIsSharedBetweenTheViews() throws {
        let window = MainWindowController()
        let (original, clone) = try cloned(window, try file("a.txt"))
        clone.setLanguage(try XCTUnwrap(LanguageCatalog.shared.language(named: "sql")))
        XCTAssertEqual(original.language.name, "sql")

        original.isUserReadOnly = true
        XCTAssertTrue(clone.isUserReadOnly)
        XCTAssertTrue(clone.isReadOnly)
        XCTAssertEqual(clone.editor.send(SCI_GETREADONLY), 1)
        original.isUserReadOnly = false

        try clone.convertEncoding(to: .utf16LE)
        XCTAssertEqual(original.encoding, .utf16LE)
        XCTAssertTrue(original.isModified, "an encoding change is unsaved in both views")

        clone.convertLineEndings(to: .crlf)
        XCTAssertEqual(original.lineEnding, .crlf)
        close(window)
    }

    // MARK: - Closing

    func testClosingTheCloneAsksNothingAndHidesTheEmptyView() throws {
        let window = MainWindowController()
        let (original, clone) = try cloned(window, try file("a.txt"))
        clone.editor.send(SCI_APPENDTEXT, 1, string: "!")  // unsaved, but still open in the main view
        window.closeTab(at: 0, inView: 1)
        XCTAssertEqual(window.openTabs.count, 1, "closed without a Save prompt")
        XCTAssertNil(original.twin)
        XCTAssertFalse(window.isOtherViewVisible)
        XCTAssertEqual(window.activeView, 0)
        XCTAssertTrue(original.isModified, "the edit is still there")
        close(window)
    }

    func testClosingTheOriginalHandsTheDocumentToTheClone() throws {
        let window = MainWindowController()
        let url = try file("a.txt")
        let (_, clone) = try cloned(window, url)
        window.closeTab(at: 0, inView: 0)
        XCTAssertEqual(window.openTabs.count, 1)
        XCTAssertTrue(window.activeTab === clone)
        XCTAssertFalse(clone.isClone)
        XCTAssertNil(clone.twin)
        XCTAssertEqual(window.view(of: clone), 0, "the main view never stands empty")
        XCTAssertFalse(window.isOtherViewVisible)
        XCTAssertEqual(text(clone), "hello")
        clone.editor.send(SCI_APPENDTEXT, 1, string: "?")
        var saved = false
        clone.save { saved = $0 }
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello?", "it saves on its own now")
        close(window)
    }

    // MARK: - Move to Other View

    func testMoveToOtherViewAndBack() throws {
        let window = MainWindowController()
        let a = window.newTab()
        let b = window.newTab()
        window.moveToOtherView(nil)
        XCTAssertEqual(names(window, 0), [a.displayName])
        XCTAssertEqual(names(window, 1), [b.displayName])
        XCTAssertEqual(window.activeView, 1)
        XCTAssertTrue(window.activeTab === b)
        XCTAssertTrue(window.isOtherViewVisible)

        window.selectTab(at: 0, inView: 0)
        XCTAssertTrue(window.activeTab === a)
        window.switchToOtherView(nil)
        XCTAssertTrue(window.activeTab === b)

        window.moveToOtherView(nil)
        XCTAssertEqual(names(window, 0), [a.displayName, b.displayName])
        XCTAssertFalse(window.isOtherViewVisible, "an empty view is hidden")
        XCTAssertEqual(window.activeView, 0)
        close(window)
    }

    func testMovingTheMainViewsLastDocumentLeavesOneView() throws {
        let window = MainWindowController()
        let a = window.newTab()
        let b = window.newTab()
        window.moveToOtherView(nil)  // b
        window.selectTab(at: 0, inView: 0)
        window.moveToOtherView(nil)  // a: the main view empties
        XCTAssertEqual(names(window, 0), [b.displayName, a.displayName])
        XCTAssertTrue(window.panes[1].tabs.isEmpty)
        XCTAssertFalse(window.isOtherViewVisible)
        XCTAssertTrue(window.activeTab === a)
        close(window)
    }

    func testMovingACloneToItsOriginalsViewMergesThem() throws {
        let window = MainWindowController()
        let (original, _) = try cloned(window, try file("a.txt"))
        window.moveToOtherView(nil)  // the clone, back to where the original is
        XCTAssertEqual(window.openTabs.count, 1)
        XCTAssertTrue(window.activeTab === original)
        XCTAssertNil(original.twin)
        XCTAssertFalse(window.isOtherViewVisible)
        close(window)
    }

    func testSwitchToOtherViewNeedsTwoViews() {
        let window = MainWindowController()
        window.newTab()
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.switchToOtherView(_:)), keyEquivalent: "")
        XCTAssertFalse(window.validateMenuItem(item))
        window.newTab()
        window.moveToOtherView(nil)
        XCTAssertTrue(window.validateMenuItem(item))
        close(window)
    }

    // MARK: - Focus

    func testTheFocusFollowsTheEditor() throws {
        let window = MainWindowController()
        let a = window.newTab()
        let b = window.newTab()
        window.moveToOtherView(nil)
        XCTAssertEqual(window.activeView, 1)
        a.onFocus?()  // Scintilla's SCN_FOCUSIN for a click in the main view
        XCTAssertEqual(window.activeView, 0)
        XCTAssertTrue(window.activeTab === a)
        b.onFocus?()
        XCTAssertEqual(window.activeView, 1)
        close(window)
    }

    func testOpeningAFileFocusesTheViewThatHasIt() throws {
        let window = MainWindowController()
        window.newTab().editor.send(SCI_APPENDTEXT, 1, string: "x")  // not reused by open
        let url = try file("a.txt")
        window.open(url)
        let tab = try XCTUnwrap(window.activeTab)
        window.moveToOtherView(nil)
        window.selectTab(at: 0, inView: 0)
        window.open(url)
        XCTAssertEqual(window.activeView, 1)
        XCTAssertTrue(window.activeTab === tab)
        XCTAssertEqual(window.openTabs.count, 2, "not opened twice")
        close(window)
    }

    func testTheTabMenuOffersMoveAndClone() throws {
        let window = MainWindowController()
        let a = window.newTab()
        window.newTab()
        let menu = try XCTUnwrap(window.panes[0].tabBar.onMenu?(0))
        XCTAssertTrue(window.activeTab === a, "right-clicking a tab selects it")
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Move to Other View"))
        XCTAssertTrue(titles.contains("Clone to Other View"))
        XCTAssertTrue(titles.contains("Close"))
        close(window)
    }

    // MARK: - Monitoring

    func testAMonitoredDocumentIsNotClonedNorAClonedOneMonitored() throws {
        let window = MainWindowController()
        let url = try file("a.log")
        let (original, _) = try cloned(window, url)
        window.selectTab(at: 0, inView: 0)
        let monitor = NSMenuItem(title: "", action: #selector(MainWindowController.toggleMonitoring(_:)), keyEquivalent: "")
        XCTAssertFalse(window.validateMenuItem(monitor), "a cloned document is not monitored")
        window.closeTab(at: 0, inView: 1)
        XCTAssertTrue(window.validateMenuItem(monitor))
        try original.startMonitoring()
        window.cloneToOtherView(nil)
        XCTAssertEqual(window.openTabs.count, 1, "a monitored document is not cloned")
        close(window)
    }

    // MARK: - Synchronized scrolling

    func testScrollSyncKeepsTheOffset() {
        var sync = ScrollSync(vertical: true, horizontal: true, lineOffset: 10, xOffset: 40)
        XCTAssertTrue(sync.isOn)
        XCTAssertEqual(sync.target(fromView: 0, line: 100, x: 0).line, 110)
        XCTAssertEqual(sync.target(fromView: 0, line: 100, x: 0).x, 40)
        XCTAssertEqual(sync.target(fromView: 1, line: 100, x: 60).line, 90)
        XCTAssertEqual(sync.target(fromView: 1, line: 100, x: 60).x, 20)
        XCTAssertEqual(sync.target(fromView: 1, line: 3, x: 10).line, 0, "never above the first line")
        XCTAssertEqual(sync.target(fromView: 1, line: 3, x: 10).x, 0)
        sync.vertical = false
        sync.horizontal = false
        XCTAssertFalse(sync.isOn)
    }

    func testSynchronizeVerticalScrolling() throws {
        let window = MainWindowController()
        let long = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let (original, clone) = try cloned(window, try file("long.txt", long))
        window.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        original.editor.send(SCI_SETFIRSTVISIBLELINE, 0)
        clone.editor.send(SCI_SETFIRSTVISIBLELINE, 10)
        window.selectTab(at: 0, inView: 0)

        window.toggleSyncVerticalScrolling(nil)
        XCTAssertTrue(window.scrollSync.vertical)
        XCTAssertEqual(window.scrollSync.lineOffset, 10)
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.toggleSyncVerticalScrolling(_:)), keyEquivalent: "")
        _ = window.validateMenuItem(item)
        XCTAssertEqual(item.state, .on)

        original.editor.send(SCI_SETFIRSTVISIBLELINE, 100)
        original.onScroll?()  // SCN_UPDATEUI with SC_UPDATE_V_SCROLL
        XCTAssertEqual(clone.editor.send(SCI_GETFIRSTVISIBLELINE), 110)

        clone.editor.send(SCI_SETFIRSTVISIBLELINE, 300)
        clone.onScroll?()
        XCTAssertEqual(original.editor.send(SCI_GETFIRSTVISIBLELINE), 100, "only the focused view leads")

        window.switchToOtherView(nil)
        clone.onScroll?()
        XCTAssertEqual(original.editor.send(SCI_GETFIRSTVISIBLELINE), 290, "the other view leads the other way")

        window.toggleSyncVerticalScrolling(nil)
        clone.editor.send(SCI_SETFIRSTVISIBLELINE, 50)
        clone.onScroll?()
        XCTAssertEqual(original.editor.send(SCI_GETFIRSTVISIBLELINE), 290, "off: the views scroll on their own")
        close(window)
    }

    func testSynchronizeHorizontalScrolling() throws {
        let window = MainWindowController()
        let wide = String(repeating: "x", count: 2000)
        let (original, clone) = try cloned(window, try file("wide.txt", wide))
        // The scroll width grows as lines are painted; nothing is painted headless.
        [original, clone].forEach { $0.editor.send(SCI_SETSCROLLWIDTH, 20000) }
        window.selectTab(at: 0, inView: 0)
        window.toggleSyncHorizontalScrolling(nil)
        XCTAssertTrue(window.scrollSync.horizontal)
        XCTAssertFalse(window.scrollSync.vertical)
        original.editor.send(SCI_SETXOFFSET, 120)
        original.onScroll?()
        XCTAssertEqual(clone.editor.send(SCI_GETXOFFSET), 120)
        close(window)
    }

    // MARK: - Session

    func testTheSessionKeepsBothViews() throws {
        let window = MainWindowController()
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt")
        window.open(a)
        window.open(b)
        window.open(c)
        window.moveToOtherView(nil)  // c
        window.selectTab(at: 1, inView: 0)
        window.cloneToOtherView(nil)  // b, in both views
        let state = window.captureSession()
        XCTAssertEqual(state.documents.map(\.path), [a.path, b.path])
        XCTAssertEqual(state.subDocuments.map(\.path), [c.path, b.path])
        XCTAssertEqual(state.activeIndex, 1)
        XCTAssertEqual(state.subActiveIndex, 1)
        XCTAssertEqual(state.activeView, 1)
        close(window)

        let decoded = try XCTUnwrap(SessionState.decoded(from: try state.encoded()))
        XCTAssertEqual(decoded, state)

        let restored = MainWindowController()
        XCTAssertTrue(restored.restore(decoded))
        XCTAssertEqual(names(restored, 0), ["a.txt", "b.txt"])
        XCTAssertEqual(names(restored, 1), ["c.txt", "b.txt"])
        XCTAssertEqual(restored.activeView, 1)
        let mainB = restored.panes[0].tabs[1], subB = restored.panes[1].tabs[1]
        XCTAssertTrue(subB.isClone, "a document in both views comes back as a clone")
        XCTAssertTrue(subB.twin === mainB)
        XCTAssertEqual(subB.editor.send(SCI_GETDOCPOINTER), mainB.editor.send(SCI_GETDOCPOINTER))
        XCTAssertTrue(restored.activeTab === subB)
        XCTAssertTrue(restored.isOtherViewVisible)
        close(restored)
    }

    func testOlderSessionsHaveOneView() throws {
        let json = #"{"version":1,"activeIndex":0,"documents":[{"path":"/tmp/a.txt","caretPosition":0,"firstVisibleLine":0}]}"#
        let state = try XCTUnwrap(SessionState.decoded(from: Data(json.utf8)))
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertTrue(state.subDocuments.isEmpty)
        XCTAssertEqual(state.activeView, 0)
    }

    func testFilteringASessionCoversBothViews() {
        let state = SessionState(documents: [.init(path: "/a"), .init(path: "/gone")], activeIndex: 1,
                                 subDocuments: [.init(path: "/gone2")], subActiveIndex: 0, activeView: 1)
        let filtered = state.filtered { !$0.hasPrefix("/gone") }
        XCTAssertEqual(filtered.documents.map(\.path), ["/a"])
        XCTAssertEqual(filtered.activeIndex, 0)
        XCTAssertTrue(filtered.subDocuments.isEmpty)
        XCTAssertEqual(filtered.activeView, 0, "the focus cannot stay in an empty view")
        XCTAssertFalse(filtered.isEmpty)
        XCTAssertFalse(SessionState(subDocuments: [.init(path: "/b")]).isEmpty)
    }

    func testOnlyTheOtherViewSurvivingStillRestores() throws {
        let b = try file("b.txt")
        let window = MainWindowController()
        let state = SessionState(documents: [.init(path: folder.appendingPathComponent("gone.txt").path)],
                                 subDocuments: [.init(path: b.path)], activeView: 1)
        XCTAssertTrue(window.restore(state))
        XCTAssertEqual(names(window, 0), ["b.txt"], "the main view never stands empty")
        XCTAssertFalse(window.isOtherViewVisible)
        XCTAssertEqual(window.activeView, 0)
        close(window)
    }
}
