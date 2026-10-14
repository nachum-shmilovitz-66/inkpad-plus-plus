import XCTest
@testable import MacPad

// MAC-33: Find in Files / Replace in Files — the filter, the folder walk, the job and the tab.

private func makeEditor(_ text: String) -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
    v.setUTF8Bytes(Data(text.utf8))
    return v
}

/// A throwaway folder tree, removed after each test.
private final class Tree {
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPadFIF-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    @discardableResult
    func file(_ path: String, _ data: Data) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }
    @discardableResult
    func file(_ path: String, _ text: String) -> URL { file(path, Data(text.utf8)) }
    func text(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }
    func names(_ urls: [URL]?) -> [String] {
        (urls ?? []).map { String($0.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1)) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

final class FileFilterTests: XCTestCase {
    func testEmptyMeansEverything() {
        let f = FileFilter("  ")
        XCTAssertEqual(f.text, "*.*")
        XCTAssertTrue(f.matchesFile(named: "Makefile"), "*.* matches names without a dot")
        XCTAssertTrue(f.matchesFile(named: "a.txt"))
    }

    func testIncludesAndExcludesIgnoringCase() {
        let f = FileFilter("*.cpp *.H")
        XCTAssertTrue(f.matchesFile(named: "main.CPP"))
        XCTAssertTrue(f.matchesFile(named: "x.h"))
        XCTAssertFalse(f.matchesFile(named: "x.txt"))
        let g = FileFilter("*.* !*.exe !*.LOG")
        XCTAssertTrue(g.matchesFile(named: "a.txt"))
        XCTAssertFalse(g.matchesFile(named: "run.exe"))
        XCTAssertFalse(g.matchesFile(named: "x.log"), "exclusions win")
    }

    func testOnlyExclusionsIncludeEverythingElse() {
        let f = FileFilter("!*.bin")
        XCTAssertTrue(f.matchesFile(named: "a.txt"))
        XCTAssertFalse(f.matchesFile(named: "a.bin"))
    }

    func testFolderExclusions() {
        let f = FileFilter("*.* !\\tests !/bin* !+\\log*")
        XCTAssertTrue(f.excludesFolder(named: "tests", level: 1))
        XCTAssertFalse(f.excludesFolder(named: "tests", level: 2), "!\\folder is top level only")
        XCTAssertTrue(f.excludesFolder(named: "bin64", level: 1))
        XCTAssertTrue(f.excludesFolder(named: "logs", level: 3), "!+\\folder is any depth")
        XCTAssertFalse(f.excludesFolder(named: "src", level: 1))
        XCTAssertTrue(f.matchesFile(named: "tests"), "folder rules do not touch files")
    }

    func testSemicolonsAndQuestionMarks() {
        let f = FileFilter("*.c;*.h a?.txt")
        XCTAssertTrue(f.matchesFile(named: "x.h"))
        XCTAssertTrue(f.matchesFile(named: "ab.txt"))
        XCTAssertFalse(f.matchesFile(named: "abc.txt"))
    }
}

final class FileCollectorTests: XCTestCase {
    func testDepthFirstInNameOrder() {
        let t = Tree()
        t.file("b.txt", "b")
        t.file("a/z.txt", "z")
        t.file("a/c.txt", "c")
        t.file("A2.txt", "x")
        XCTAssertEqual(t.names(FileCollector.files(in: t.root, filter: FileFilter(""), recursive: true, includeHiddenFolders: false)),
                       ["a/c.txt", "a/z.txt", "A2.txt", "b.txt"])
        XCTAssertEqual(t.names(FileCollector.files(in: t.root, filter: FileFilter(""), recursive: false, includeHiddenFolders: false)),
                       ["A2.txt", "b.txt"])
    }

    func testHiddenFoldersOnlyWhenAskedButHiddenFilesAlways() {
        let t = Tree()
        t.file(".git/config", "x")
        t.file(".env", "x")
        t.file("src/a.txt", "x")
        XCTAssertEqual(t.names(FileCollector.files(in: t.root, filter: FileFilter(""), recursive: true, includeHiddenFolders: false)),
                       [".env", "src/a.txt"])
        XCTAssertEqual(t.names(FileCollector.files(in: t.root, filter: FileFilter(""), recursive: true, includeHiddenFolders: true)),
                       [".env", ".git/config", "src/a.txt"])
    }

    func testFolderExclusionsAndFilters() {
        let t = Tree()
        t.file("tests/a.cpp", "x")
        t.file("src/tests/b.cpp", "x")
        t.file("src/log/c.cpp", "x")
        t.file("src/d.cpp", "x")
        t.file("src/e.txt", "x")
        XCTAssertEqual(t.names(FileCollector.files(in: t.root, filter: FileFilter("*.cpp !/tests !+/log"), recursive: true, includeHiddenFolders: false)),
                       ["src/d.cpp", "src/tests/b.cpp"])
    }

    func testSymlinkLoopsEndAndCancelStops() throws {
        let t = Tree()
        t.file("a/x.txt", "x")
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("a/loop"), withDestinationURL: t.root)
        let files = FileCollector.files(in: t.root, filter: FileFilter(""), recursive: true, includeHiddenFolders: false)
        XCTAssertEqual(t.names(files), ["a/x.txt"])
        XCTAssertNil(FileCollector.files(in: t.root, filter: FileFilter(""), recursive: true, includeHiddenFolders: false, isCancelled: { true }))
    }
}

final class FindInFilesJobTests: XCTestCase {
    func testFindAllAcrossEncodingsListsEachFileWithHits() {
        let t = Tree()
        let utf16 = t.file("one.txt", Data([0xFF, 0xFE]) + "say שלום\r\n".data(using: .utf16LittleEndian)!)
        let plain = t.file("two.txt", "nothing here\nשלום again שלום")
        t.file("three.txt", "no match")
        let files = FileCollector.files(in: t.root, filter: FileFilter("*.txt"), recursive: true, includeHiddenFolders: false)!
        let job = FindInFilesJob(text: "שלום", kind: .findAll, options: SearchOptions(), files: files)
        guard case .found(let block) = job.runToCompletion() else { return XCTFail() }
        XCTAssertEqual(block.header, "Search \"שלום\" (3 hits in 2 files of 3 searched) [Normal]")
        XCTAssertEqual(block.files.map(\.path), [utf16.path, plain.path])
        XCTAssertEqual(block.files[1].hits.first?.text, "\tLine 2: שלום again שלום")
    }

    func testAnOpenDocumentIsSearchedInItsBuffer() {
        let t = Tree()
        let url = t.file("open.txt", "old text")
        let editor = makeEditor("new unsaved text")
        let job = FindInFilesJob(text: "unsaved", kind: .findAll, options: SearchOptions(), files: [url]) {
            $0 == url ? .init(editor: editor, save: {}) : nil
        }
        guard case .found(let block) = job.runToCompletion() else { return XCTFail() }
        XCTAssertEqual(block.hitCount, 1)
    }

    func testReplaceKeepsEncodingBOMLineEndingsAndPermissions() throws {
        let t = Tree()
        let utf16 = t.file("u.txt", Data([0xFF, 0xFE]) + "a cat\r\nb cat\r\n".data(using: .utf16LittleEndian)!)
        let script = t.file("run.sh", "echo cat\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let job = FindInFilesJob(text: "cat", kind: .replace("dog"), options: SearchOptions(), files: [utf16, script])
        XCTAssertEqual(job.runToCompletion(), .replaced(3, failed: []))
        XCTAssertEqual(try Data(contentsOf: utf16), Data([0xFF, 0xFE]) + "a dog\r\nb dog\r\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(t.text("run.sh"), "echo dog\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
    }

    func testReplaceSkipsReadOnlyFilesAndSavesOpenDocuments() throws {
        let t = Tree()
        let locked = t.file("locked.txt", "cat")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let openURL = t.file("open.txt", "cat on disk")
        let editor = makeEditor("cat in buffer")
        var saved = 0
        let job = FindInFilesJob(text: "cat", kind: .replace("dog"), options: SearchOptions(), files: [locked, openURL]) {
            $0 == openURL ? .init(editor: editor, save: { saved += 1 }) : nil
        }
        XCTAssertEqual(job.runToCompletion(), .replaced(1, failed: []))
        XCTAssertEqual(t.text("locked.txt"), "cat")
        XCTAssertEqual(String(decoding: editor.utf8Bytes(), as: UTF8.self), "dog in buffer")
        XCTAssertEqual(saved, 1, "the open document is saved, as Notepad++ does")
    }

    func testInvalidRegexStopsTheRun() {
        let t = Tree()
        let url = t.file("a.txt", "x")
        let job = FindInFilesJob(text: "(", kind: .findAll, options: SearchOptions(mode: .regex), files: [url, url])
        XCTAssertEqual(job.runToCompletion(), .invalidRegex)
    }

    func testStepsCanBeCancelled() {
        let t = Tree()
        let files = (0..<5).map { t.file("f\($0).txt", "x") }
        let job = FindInFilesJob(text: "x", kind: .findAll, options: SearchOptions(), files: files)
        job.cancel()
        XCTAssertFalse(job.step())
        guard case .found(let block) = job.outcome else { return XCTFail() }
        XCTAssertEqual(block.hitCount, 0, "nothing searched after Cancel")
    }

    func testOptionsDecodeFromAnOlderSave() throws {
        let old = #"{"mode":"regex","matchCase":true,"wholeWord":false,"wrapAround":true,"backward":false,"inSelection":false,"dotMatchesNewline":true}"#
        let options = try JSONDecoder().decode(SearchOptions.self, from: Data(old.utf8))
        XCTAssertEqual(options.mode, .regex)
        XCTAssertTrue(options.matchCase)
        XCTAssertTrue(options.inAllSubfolders, "a key the old save lacks keeps its default")
        XCTAssertFalse(options.inHiddenFolders)
    }
}

final class FindInFilesTabTests: XCTestCase {
    private let suite = "app.macpad.MacPad.tests.fif"
    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func controller() -> FindReplaceController {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let c = FindReplaceController(defaults: defaults) { makeEditor("") }
        c.runsFindInFilesSynchronously = true
        return c
    }

    func testTheTabShowsItsOwnControls() {
        let c = controller()
        c.setTab(.findInFiles)
        XCTAssertEqual(c.window?.title, "Find in Files")
        XCTAssertFalse(c.findInFilesButton.isHidden)
        XCTAssertFalse(c.replaceInFilesButton.isHidden)
        XCTAssertFalse(c.subfoldersBox.isHidden)
        XCTAssertTrue(c.findNextButton.isHidden)
        XCTAssertTrue(c.wrapBox.isHidden)
        XCTAssertTrue(c.backwardBox.isHidden)
        XCTAssertEqual(c.subfoldersBox.state, .on, "In all sub-folders is on by default")
        XCTAssertEqual(c.hiddenFoldersBox.state, .off)
        c.setTab(.find)
        XCTAssertTrue(c.findInFilesButton.isHidden)
        XCTAssertFalse(c.wrapBox.isHidden)
    }

    func testFindAllInADirectory() {
        let t = Tree()
        t.file("a.txt", "needle")
        t.file("sub/b.log", "needle needle")
        let c = controller()
        var blocks: [SearchResultsBlock] = []
        c.resultsSink = { blocks.append($0) }
        c.setTab(.findInFiles)
        c.findField.stringValue = "needle"
        c.filtersField.stringValue = ""
        c.directoryField.stringValue = t.root.path
        c.findInFiles(replacing: false)
        XCTAssertEqual(c.filtersField.stringValue, "*.*", "an empty filter shows as *.*")
        XCTAssertEqual(blocks.last?.header, "Search \"needle\" (3 hits in 2 files of 2 searched) [Normal]")
        XCTAssertEqual(c.directoryHistory.items, [t.root.path])
        XCTAssertEqual(c.filterHistory.items, ["*.*"])
        c.subfoldersBox.performClick(nil)
        c.findInFiles(replacing: false)
        XCTAssertEqual(blocks.last?.header, "Search \"needle\" (1 hit in 1 file of 1 searched) [Normal]")
    }

    func testAMissingDirectoryDoesNothing() {
        let c = controller()
        var called = false
        c.resultsSink = { _ in called = true }
        c.findField.stringValue = "x"
        c.directoryField.stringValue = "/no/such/folder"
        c.findInFiles(replacing: false)
        XCTAssertFalse(called)
    }

    func testReplaceInFilesAsksFirst() {
        let t = Tree()
        t.file("a.txt", "cat cat")
        t.file("b.txt", "cat")
        let c = controller()
        var asked: (String, String)?
        var answer = false
        c.confirmReplaceInFiles = { directory, filters in asked = (directory, filters); return answer }
        c.findField.stringValue = "cat"
        c.replaceField.stringValue = "dog"
        c.filtersField.stringValue = "*.txt"
        c.directoryField.stringValue = t.root.path
        c.findInFiles(replacing: true)
        XCTAssertEqual(asked?.0, t.root.path)
        XCTAssertEqual(asked?.1, "*.txt")
        XCTAssertEqual(t.text("a.txt"), "cat cat", "declined: nothing changes")
        answer = true
        c.findInFiles(replacing: true)
        XCTAssertEqual(t.text("a.txt"), "dog dog")
        XCTAssertEqual(t.text("b.txt"), "dog")
        XCTAssertEqual(c.status?.text, "Replace in Files: 3 occurrences were replaced.")
    }

    func testFillDirectoryFromTheActiveDocument() {
        let t = Tree()
        let url = t.file("doc.txt", "x")
        let c = controller()
        c.documentsProvider = { (SearchDocument(editor: makeEditor(""), path: url.path), []) }
        c.directoryField.stringValue = ""
        c.fillDirectoryFromActiveDocument()
        XCTAssertEqual(c.directoryField.stringValue, t.root.path)
        c.directoryField.stringValue = "/kept"
        c.documentsProvider = { (SearchDocument(editor: makeEditor(""), path: "new 1"), []) }
        c.fillDirectoryFromActiveDocument()
        XCTAssertEqual(c.directoryField.stringValue, "/kept", "an untitled document has no directory")
    }
}
