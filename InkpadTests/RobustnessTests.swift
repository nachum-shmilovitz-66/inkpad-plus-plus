import XCTest
@testable import Inkpad

/// MAC-63: what a crafted session, macros file or huge file can no longer do.
final class RobustnessTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Regression: activeView 7 with documents in the other view crashed every launch.
    func testACraftedSessionViewIsClamped() throws {
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        for view in [7, -1, Int.max] {
            let window = MainWindowController()
            XCTAssertTrue(window.restore(SessionState(documents: [.init(path: a.path)], subDocuments: [.init(path: b.path)], activeView: view)))
            XCTAssertTrue((0...1).contains(window.activeView))
            XCTAssertNotNil(window.activeTab)
            window.openTabs.forEach { $0.detach() }
        }
    }

    /// Regression: a hand-edited macros.json could send any selector through the responder chain.
    func testMacrosPlayOnlyRecordableCommands() {
        XCTAssertFalse(MacroRecorder.isRecordable(#selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        let before = NSApp.windows.filter(\.isVisible).count
        var touched: [ScintillaView] = []
        let editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        MacroRecorder.shared.play([.command(#selector(NSApplication.orderFrontStandardAboutPanel(_:)))],
                                  editor: { editor }, search: { _ in }, touched: &touched)
        MacroRecorder.endUndoGroups(touched)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, before, "no About panel: the command was not played")
    }

    func testFilesOverTheLimitAreRefusedBeforeReading() throws {
        let saved = TextFile.maximumOpenSize
        TextFile.maximumOpenSize = 10
        defer { TextFile.maximumOpenSize = saved }
        let big = dir.appendingPathComponent("big.log")
        try Data(repeating: 65, count: 11).write(to: big)
        XCTAssertThrowsError(try TextFile.read(big)) { XCTAssertEqual($0 as? TextFile.TooLarge, TextFile.TooLarge(size: 11)) }
        let tab = EditorTab(untitledNumber: 1)
        defer { tab.detach() }
        XCTAssertThrowsError(try tab.load(big), "the editor refuses it, as upstream refuses files over 2 GB")
        let small = dir.appendingPathComponent("small.txt")
        try Data("ok".utf8).write(to: small)
        XCTAssertEqual(try TextFile.read(small), Data("ok".utf8))
        XCTAssertEqual(saved, 2 * 1024 * 1024 * 1024)
    }

    func testFindInFilesSkipsFilesOverTheLimit() throws {
        let saved = TextFile.maximumOpenSize
        TextFile.maximumOpenSize = 10
        defer { TextFile.maximumOpenSize = saved }
        try Data("needle".utf8).write(to: dir.appendingPathComponent("small.txt"))
        try Data("needle and much more".utf8).write(to: dir.appendingPathComponent("big.txt"))
        let files = FileCollector.files(in: dir, filter: FileFilter(""), recursive: false, includeHiddenFolders: false) ?? []
        XCTAssertEqual(files.count, 2)
        XCTAssertNoThrow(try TextFile.read(dir.appendingPathComponent("small.txt")))
        XCTAssertThrowsError(try TextFile.read(dir.appendingPathComponent("big.txt")))
    }
}
