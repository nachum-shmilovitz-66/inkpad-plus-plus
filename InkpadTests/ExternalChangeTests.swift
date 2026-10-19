import XCTest
@testable import Inkpad

/// What to do about a file another program changed or deleted.
final class ExternalChangePolicyTests: XCTestCase {
    private func action(_ change: FileChange, modified: Bool = false, silent: Bool = false) -> ExternalChangeAction {
        ExternalChangePolicy.action(for: change, isModified: modified, updateSilently: silent)
    }

    func testUnchangedNeedsNothing() {
        XCTAssertEqual(action(.unchanged), .none)
        XCTAssertEqual(action(.unchanged, modified: true, silent: true), .none)
    }

    func testModifiedFileAsksToReload() {
        XCTAssertEqual(action(.replaced), .ask(.reload(losesEdits: false)))
        XCTAssertEqual(action(.appended(from: 3)), .ask(.reload(losesEdits: false)))
    }

    func testUnsavedEditsAreCalledOut() {
        XCTAssertEqual(action(.replaced, modified: true), .ask(.reload(losesEdits: true)))
    }

    func testUpdateSilentlyReloadsOnlyWhenNothingIsLost() {
        XCTAssertEqual(action(.replaced, silent: true), .reloadSilently)
        XCTAssertEqual(action(.replaced, modified: true, silent: true), .ask(.reload(losesEdits: true)))
    }

    func testDeletedFileAlwaysAsks() {
        XCTAssertEqual(action(.missing), .ask(.keepDeleted))
        XCTAssertEqual(action(.missing, silent: true), .ask(.keepDeleted))
    }

    func testPromptTexts() {
        let plain = ExternalChangePrompt.reload(losesEdits: false).texts(path: "/var/log/app.log")
        XCTAssertEqual(plain.title, "\"app.log\" was modified by another program")
        XCTAssertTrue(plain.message.hasPrefix("/var/log/app.log"))
        XCTAssertTrue(plain.message.hasSuffix("Do you want to reload it?"))
        XCTAssertEqual(plain.yes, "Reload")

        let lossy = ExternalChangePrompt.reload(losesEdits: true).texts(path: "/a/b.txt")
        XCTAssertTrue(lossy.message.contains("lose the changes"))
        XCTAssertEqual(lossy.no, "Keep My Changes")

        let deleted = ExternalChangePrompt.keepDeleted.texts(path: "/a/b.txt")
        XCTAssertEqual(deleted.title, "\"b.txt\" doesn't exist anymore")
        XCTAssertEqual([deleted.yes, deleted.no], ["Keep", "Close"])
    }
}

/// Preferences default to upstream's: detection on, not silent.
final class FileStatusPreferencesTests: XCTestCase {
    override func tearDown() {
        AppEnvironment.defaults.removeObject(forKey: FileStatusPreferences.enabledKey)
        AppEnvironment.defaults.removeObject(forKey: FileStatusPreferences.updateSilentlyKey)
    }

    func testDefaults() {
        XCTAssertTrue(FileStatusPreferences.isEnabled)
        XCTAssertFalse(FileStatusPreferences.updateSilently)
    }

    func testStoredValuesAreRead() {
        AppEnvironment.defaults.set(false, forKey: FileStatusPreferences.enabledKey)
        AppEnvironment.defaults.set(true, forKey: FileStatusPreferences.updateSilentlyKey)
        XCTAssertFalse(FileStatusPreferences.isEnabled)
        XCTAssertTrue(FileStatusPreferences.updateSilently)
    }
}

/// A real editor noticing changes made by "another program" (the test) to its file.
final class EditorTabExternalChangeTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadExt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("notes.txt")
    }

    override func tearDownWithError() throws {
        AppEnvironment.defaults.removeObject(forKey: FileStatusPreferences.enabledKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func openTab(_ text: String) throws -> EditorTab {
        try Data(text.utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        addTeardownBlock { tab.detach() }
        return tab
    }

    private func text(_ tab: EditorTab) -> String { String(decoding: tab.editor.utf8Bytes(), as: UTF8.self) }

    /// Another program saving the file: a new file renamed over it, like most editors.
    private func otherProgramSaves(_ text: String) throws { try Data(text.utf8).write(to: url, options: .atomic) }

    // MARK: Detecting

    func testAChangeByAnotherProgramIsReportedOnce() throws {
        let tab = try openTab("v1")
        var reports = 0
        tab.onExternalChange = { _ in reports += 1 }
        try otherProgramSaves("v2")
        tab.checkDiskState()
        tab.checkDiskState()
        XCTAssertEqual(tab.pendingExternalChange, .replaced)
        XCTAssertEqual(reports, 1, "reported once until resolved")
    }

    func testAnInPlaceAppendIsAlsoAChange() throws {
        let tab = try openTab("v1")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" more".utf8))
        try handle.close()
        tab.checkDiskState()
        XCTAssertEqual(tab.pendingExternalChange, .appended(from: 2))
    }

    func testOurOwnSaveIsNeverReported() throws {
        let tab = try openTab("mine")
        tab.editor.send(SCI_APPENDTEXT, 1, string: "!")
        tab.save()
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange)
    }

    func testNothingChangedNothingReported() throws {
        let tab = try openTab("same")
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange)
    }

    func testDetectionCanBeTurnedOff() throws {
        AppEnvironment.defaults.set(false, forKey: FileStatusPreferences.enabledKey)
        let tab = try openTab("v1")
        try otherProgramSaves("v2")
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange)
    }

    func testAMonitoredTabIsNotPrompted() throws {
        let tab = try openTab("log\n")
        try tab.startMonitoring(pollInterval: 60)
        try otherProgramSaves("rotated\n")
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange, "monitoring reloads by itself")
    }

    // MARK: Reloading or not

    func testReloadReadsTheNewTextAndKeepsTheCaretLine() throws {
        let tab = try openTab("one\ntwo\nthree\n")
        tab.editor.send(SCI_GOTOPOS, tab.editor.send(SCI_FINDCOLUMN, 1, 2))  // line 1, column 2
        try otherProgramSaves("ONE\nTWO\nTHREE\nFOUR\n")
        tab.checkDiskState()
        tab.resolveExternalChange(accept: true)

        XCTAssertEqual(text(tab), "ONE\nTWO\nTHREE\nFOUR\n")
        let pos = tab.editor.send(SCI_GETCURRENTPOS)
        XCTAssertEqual(tab.editor.send(SCI_LINEFROMPOSITION, pos), 1)
        XCTAssertEqual(tab.editor.send(SCI_GETCOLUMN, pos), 2)
        XCTAssertFalse(tab.isModified)
        XCTAssertNil(tab.pendingExternalChange)
    }

    func testReloadIntoAShorterFileClampsTheCaret() throws {
        let tab = try openTab("1\n2\n3\n4\n5\n")
        tab.editor.send(SCI_DOCUMENTEND)
        try otherProgramSaves("only\n")
        tab.checkDiskState()
        tab.resolveExternalChange(accept: true)
        XCTAssertEqual(text(tab), "only\n")
        XCTAssertLessThanOrEqual(tab.editor.send(SCI_GETCURRENTPOS), tab.editor.send(SCI_GETLENGTH))
    }

    func testReloadThrowsAwayUnsavedEditsOnlyWhenAccepted() throws {
        let tab = try openTab("disk v1")
        tab.editor.send(SCI_APPENDTEXT, 6, string: " edits")
        try otherProgramSaves("disk v2")
        tab.checkDiskState()

        tab.resolveExternalChange(accept: false)
        XCTAssertEqual(text(tab), "disk v1 edits", "declining keeps the user's edits")
        XCTAssertTrue(tab.isModified)
    }

    func testDecliningIsNotAskedAgainUntilTheNextChange() throws {
        let tab = try openTab("v1")
        try otherProgramSaves("v2")
        tab.checkDiskState()
        tab.resolveExternalChange(accept: false)
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange)

        try otherProgramSaves("v3 is longer")
        tab.checkDiskState()
        XCTAssertEqual(tab.pendingExternalChange, .replaced)
    }

    func testReloadKeepsTheDetectedEncoding() throws {
        let tab = try openTab("ascii")
        let utf16LE: [UInt8] = [0xFF, 0xFE, 0x68, 0x00, 0xE9, 0x00]  // BOM + "hé"
        try Data(utf16LE).write(to: url, options: .atomic)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), utf16LE)
        tab.checkDiskState()
        tab.resolveExternalChange(accept: true)
        XCTAssertEqual(text(tab), "hé")
        XCTAssertEqual(tab.encoding, .utf16LE)
    }

    // MARK: Deleted files

    func testDeletedFileIsReportedAndKeptAsUnsaved() throws {
        let tab = try openTab("precious")
        try FileManager.default.removeItem(at: url)
        tab.checkDiskState()
        XCTAssertEqual(tab.pendingExternalChange, .missing)

        tab.resolveExternalChange(accept: true)  // Keep
        XCTAssertTrue(tab.isModified, "kept after deletion = unsaved")
        XCTAssertEqual(text(tab), "precious")

        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange, "still gone is not a new question")

        tab.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "precious", "saving writes it back")
        XCTAssertFalse(tab.isModified)
    }

    func testAKeptDeletedFileThatReturnsOffersAReload() throws {
        let tab = try openTab("old")
        try FileManager.default.removeItem(at: url)
        tab.checkDiskState()
        tab.resolveExternalChange(accept: true)
        try otherProgramSaves("restored")
        tab.checkDiskState()
        XCTAssertEqual(tab.pendingExternalChange, .replaced)
        tab.resolveExternalChange(accept: true)
        XCTAssertEqual(text(tab), "restored")
        XCTAssertFalse(tab.isModified)
    }

    // MARK: The live watcher

    func testTheWatcherNoticesAChangeByItself() throws {
        let tab = try openTab("before")
        var reported = false
        tab.onExternalChange = { _ in reported = true }
        try otherProgramSaves("after")
        let deadline = Date().addingTimeInterval(6)
        while !reported, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(reported)
        XCTAssertEqual(tab.pendingExternalChange, .replaced)
    }
}
