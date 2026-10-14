import XCTest
@testable import MacPad

/// MAC-52: the `macpad` tool's options (Notepad++'s command line) and how MacPad++ applies them.
final class CommandLineTests: XCTestCase {
    private func parse(_ args: String...) throws -> CommandLineOptions { try CommandLineOptions.parse(args) }

    // MARK: - Parsing

    func testFilesAndCaretOptions() throws {
        let o = try parse("-n42", "-c7", "a.txt", "dir/b.py")
        XCTAssertEqual(o.files, ["a.txt", "dir/b.py"])
        XCTAssertEqual(o.line, 42)
        XCTAssertEqual(o.column, 7)
        XCTAssertEqual(o.caret, .line(42, column: 7))
        XCTAssertEqual(try parse("-p120", "-n3", "x").caret, .position(120), "-p wins over -n")
        XCTAssertEqual(try parse("-c9", "x").caret, nil, "-c counts only with -n")
        XCTAssertEqual(try parse("-n0", "x").caret, .line(1, column: nil))
        XCTAssertNil(try parse("x").caret)
    }

    func testFlags() throws {
        let o = try parse("-ro", "-nosession", "-monitor", "-r", "-openFoldersAsWorkspace", "-lPython", "f")
        XCTAssertTrue(o.readOnly)
        XCTAssertTrue(o.noSession)
        XCTAssertTrue(o.monitor)
        XCTAssertTrue(o.recursive)
        XCTAssertTrue(o.foldersAsWorkspace)
        XCTAssertEqual(o.language, "Python")
        XCTAssertTrue(o.hasDocumentOptions)
        XCTAssertFalse(try parse("f").hasDocumentOptions)
        XCTAssertTrue(try parse("--help").help)
        XCTAssertTrue(try parse("-h").help)
    }

    func testNotepadPlusPlusOptionsWithNoMeaningHereAreIgnored() throws {
        let o = try parse("-multiInst", "-noPlugin", "-x100", "-y200", "-notabbar", "-alwaysOnTop", "-LfR",
                          "-pluginMessage=hi", "-loadingTime", "-titleAdd=X", "-settingsDir=/tmp", "-udl=Markdown",
                          "-monitoringMode", "-qt=quote", "f.txt")
        XCTAssertEqual(o, CommandLineOptions(files: ["f.txt"]))
    }

    func testDoubleDashEndsTheOptions() throws {
        let o = try parse("-ro", "--", "-n5", "--help", "-")
        XCTAssertEqual(o.files, ["-n5", "--help", "-"])
        XCTAssertTrue(o.readOnly)
        XCTAssertNil(o.line)
        XCTAssertFalse(o.help)
    }

    func testBadOptions() {
        XCTAssertThrowsError(try parse("-nabc")) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .badNumber("-nabc")) }
        XCTAssertThrowsError(try parse("-n")) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .missingValue("-n")) }
        XCTAssertThrowsError(try parse("-n-3")) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .badNumber("-n-3")) }
        XCTAssertThrowsError(try parse("-l")) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .missingValue("-l")) }
        XCTAssertThrowsError(try parse("-bogus")) { XCTAssertEqual($0 as? CommandLineOptions.ParseError, .unknownOption("-bogus")) }
        XCTAssertTrue(CommandLineOptions.ParseError.unknownOption("-q").localizedDescription.contains("--help"))
    }

    func testPathsAreTheShells() {
        XCTAssertEqual(CommandLineOptions.absolutePath("a.txt", cwd: "/Users/me/src"), "/Users/me/src/a.txt")
        XCTAssertEqual(CommandLineOptions.absolutePath("../b c.txt", cwd: "/Users/me/src"), "/Users/me/b c.txt")
        XCTAssertEqual(CommandLineOptions.absolutePath("/etc/hosts", cwd: "/Users/me"), "/etc/hosts")
        XCTAssertEqual(CommandLineOptions.absolutePath("~/x", cwd: "/"), NSHomeDirectory() + "/x")
    }

    func testTheUsageListsEveryOption() {
        for flag in ["-n<line>", "-c<column>", "-p<position>", "-l<language>", "-ro", "-monitor", "-r ",
                     "-openFoldersAsWorkspace", "-nosession", "--help"] {
            XCTAssertTrue(CommandLineOptions.usage.contains(flag), flag)
        }
    }

    func testTheOptionsRideOnTheOpenDocumentsEvent() throws {
        let options = CommandLineOptions(files: ["/tmp/a b.txt", "/tmp/c.py"], line: 3, column: 2, language: "python", readOnly: true)
        let event = options.openDocumentsEvent()
        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEOpenDocuments))
        let list = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
        XCTAssertEqual(list.numberOfItems, 2)
        XCTAssertEqual(list.atIndex(1)?.fileURLValue?.path, "/tmp/a b.txt")
        XCTAssertEqual(CommandLineOptions.from(event: event), options)
        XCTAssertNil(CommandLineOptions.from(event: nil))
        XCTAssertNil(CommandLineOptions.from(event: NSAppleEventDescriptor.list()), "a plain Finder event has none")
    }

    func testNoSessionSkipsTheSessionAtLaunch() {
        XCTAssertTrue(AppDelegate.shouldRestoreSession(arguments: ["/Applications/MacPad++.app/Contents/MacOS/MacPad++"]))
        XCTAssertFalse(AppDelegate.shouldRestoreSession(arguments: ["MacPad++", "-nosession"]))
    }

    // MARK: - Applying them

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CommandLineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func file(_ name: String, _ text: String = "text") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func window() -> MainWindowController {
        let window = MainWindowController()
        window.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        return window
    }

    func testLineAndColumnPutTheCaretAndCentreIt() throws {
        let url = try file("long.txt", (1...300).map { "line \($0)" }.joined(separator: "\n"))
        let window = window()
        window.open([url], options: try CommandLineOptions.parse(["-n150", "-c3"]))
        let editor = try XCTUnwrap(window.activeTab?.editor)
        let caret = editor.send(SCI_GETCURRENTPOS)
        XCTAssertEqual(editor.send(SCI_LINEFROMPOSITION, caret), 149)
        XCTAssertEqual(editor.send(SCI_GETCOLUMN, caret), 2)
        let first = editor.send(SCI_GETFIRSTVISIBLELINE), onScreen = editor.send(SCI_LINESONSCREEN)
        XCTAssertGreaterThan(onScreen, 10)
        XCTAssertEqual(first, 149 - onScreen / 2, "the caret's line in the middle")
        window.openTabs.forEach { $0.detach() }
    }

    func testAPositionNeverLandsInsideACharacter() throws {
        let url = try file("utf8.txt", "אב\r\nc")  // א = 2 bytes, ב = 2 bytes, then CR LF
        let window = window()
        window.open([url], options: CommandLineOptions(position: 1))
        XCTAssertEqual(window.activeTab?.caretPosition, 2, "not inside א")
        window.open([url], options: CommandLineOptions(position: 5))
        XCTAssertEqual(window.activeTab?.caretPosition, 6, "not between CR and LF")
        window.open([url], options: CommandLineOptions(position: 999))
        XCTAssertEqual(window.activeTab?.caretPosition, 7, "clamped to the end")
        window.openTabs.forEach { $0.detach() }
    }

    func testLanguageAndReadOnly() throws {
        let url = try file("script.txt")
        let window = window()
        window.open([url], options: try CommandLineOptions.parse(["-lPYTHON", "-ro"]))
        let tab = try XCTUnwrap(window.activeTab)
        XCTAssertEqual(tab.language.name, "python", "any case")
        XCTAssertTrue(tab.isUserReadOnly)
        let other = try file("other.txt")
        window.open([other], options: try CommandLineOptions.parse(["-lnosuchlanguage"]))
        XCTAssertEqual(window.activeTab?.language.name, LanguageCatalog.shared.plainText.name, "an unknown language is ignored")
        window.openTabs.forEach { $0.detach() }
    }

    func testMonitor() throws {
        let url = try file("app.log", "one\n")
        let window = window()
        window.open([url], options: CommandLineOptions(monitor: true))
        XCTAssertEqual(window.activeTab?.isMonitoring, true)
        window.openTabs.forEach { $0.detach() }
    }

    func testAFolderOpensItsFilesOrItsTreeWithR() throws {
        try file("b.txt")
        try file("a.txt")
        try file(".hidden")
        try file("sub/c.txt")
        let window = window()
        window.open([folder], options: CommandLineOptions())
        XCTAssertEqual(window.openTabs.map(\.displayName), ["a.txt", "b.txt"], "its files, by name; hidden ones and sub-folders left out")
        window.open([folder], options: CommandLineOptions(recursive: true))
        XCTAssertEqual(window.openTabs.map(\.displayName), ["a.txt", "b.txt", "c.txt"])
        window.openTabs.forEach { $0.detach() }
    }

    func testFoldersAsWorkspace() throws {
        let file = try file("a.txt")
        let window = window()
        window.open([folder, file], options: CommandLineOptions(foldersAsWorkspace: true))
        XCTAssertTrue(window.workspace.roots.contains { $0.url.standardizedFileURL == folder.standardizedFileURL })
        XCTAssertTrue(window.isWorkspaceVisible)
        XCTAssertEqual(window.openTabs.map(\.displayName), ["a.txt"], "files still open")
        window.workspace.removeAll()
        window.openTabs.forEach { $0.detach() }
    }

    func testFinderOpensAreUnchanged() throws {
        let url = try file("plain.txt")
        let window = window()
        window.open([url], options: CommandLineOptions())
        let tab = try XCTUnwrap(window.activeTab)
        XCTAssertFalse(tab.isUserReadOnly)
        XCTAssertEqual(tab.caretPosition, 0)
        XCTAssertEqual(tab.editor.send(SCI_GETFIRSTVISIBLELINE), 0)
        window.openTabs.forEach { $0.detach() }
    }
}
