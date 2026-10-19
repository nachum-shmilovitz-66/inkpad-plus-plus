import XCTest
@testable import Inkpad

/// How a watched file changed between two looks.
final class FileChangeTests: XCTestCase {
    private let base = FileSnapshot(inode: 7, size: 100, modified: 1000)

    func testSameSnapshotIsUnchanged() {
        XCTAssertEqual(FileChange.classify(previous: base, current: base), .unchanged)
    }

    func testGrowthOnTheSameFileIsAnAppendFromTheOldSize() {
        let grown = FileSnapshot(inode: 7, size: 150, modified: 1001)
        XCTAssertEqual(FileChange.classify(previous: base, current: grown), .appended(from: 100))
    }

    func testGrowthWithoutAnMtimeChangeIsStillAnAppend() {
        let grown = FileSnapshot(inode: 7, size: 101, modified: 1000)
        XCTAssertEqual(FileChange.classify(previous: base, current: grown), .appended(from: 100))
    }

    func testShrinkingIsTruncationAndRereadsEverything() {
        let truncated = FileSnapshot(inode: 7, size: 0, modified: 1001)
        XCTAssertEqual(FileChange.classify(previous: base, current: truncated), .replaced)
    }

    func testANewInodeIsRotationEvenIfLarger() {
        let rotated = FileSnapshot(inode: 8, size: 500, modified: 1001)
        XCTAssertEqual(FileChange.classify(previous: base, current: rotated), .replaced)
    }

    func testSameSizeButNewMtimeIsARewriteInPlace() {
        let rewritten = FileSnapshot(inode: 7, size: 100, modified: 1002)
        XCTAssertEqual(FileChange.classify(previous: base, current: rewritten), .replaced)
    }

    func testDisappearingIsMissing() {
        XCTAssertEqual(FileChange.classify(previous: base, current: nil), .missing)
    }

    func testStillMissingIsUnchanged() {
        XCTAssertEqual(FileChange.classify(previous: nil, current: nil), .unchanged)
    }

    func testReappearingIsReplaced() {
        XCTAssertEqual(FileChange.classify(previous: nil, current: base), .replaced)
    }
}

/// Reading a real file's identity.
final class FileSnapshotTests: XCTestCase {
    func testSnapshotOfAFileAndOfAMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        XCTAssertNil(FileSnapshot.of(path: url.path))
        try Data("12345".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try XCTUnwrap(FileSnapshot.of(path: url.path))
        XCTAssertEqual(snap.size, 5)
        XCTAssertGreaterThan(snap.inode, 0)
    }

    func testAnAtomicReplaceGetsANewInode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try Data("a".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try XCTUnwrap(FileSnapshot.of(path: url.path))
        try Data("b".utf8).write(to: url, options: .atomic)
        let after = try XCTUnwrap(FileSnapshot.of(path: url.path))
        XCTAssertNotEqual(before.inode, after.inode)
    }
}

/// Appended bytes → UTF-8, holding back characters split across writes.
final class IncrementalDecoderTests: XCTestCase {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: UTF-8

    func testASCIIPassesStraightThrough() {
        var d = IncrementalDecoder(encoding: .utf8)
        XCTAssertEqual(text(d.feed(Data("line\n".utf8))), "line\n")
        XCTAssertTrue(d.pending.isEmpty)
    }

    func testTwoByteCharacterSplitAcrossWrites() {
        var d = IncrementalDecoder(encoding: .utf8)
        let e = [UInt8]("é".utf8)  // C3 A9
        XCTAssertEqual(text(d.feed(Data([0x61, e[0]]))), "a")
        XCTAssertEqual(d.pending, Data([e[0]]))
        XCTAssertEqual(text(d.feed(Data([e[1], 0x62]))), "éb")
        XCTAssertTrue(d.pending.isEmpty)
    }

    func testHebrewThreeWaySplit() {
        var d = IncrementalDecoder(encoding: .utf8)
        let shin = [UInt8]("ש".utf8)  // D7 A9
        let word = [UInt8]("שלום".utf8)
        XCTAssertEqual(shin.count, 2)
        var out = Data()
        for byte in word { out.append(d.feed(Data([byte]))) }
        XCTAssertEqual(text(out), "שלום")
        XCTAssertTrue(d.pending.isEmpty)
    }

    func testFourByteEmojiSplitAtEveryPoint() {
        let emoji = [UInt8]("🙂".utf8)
        for cut in 1..<emoji.count {
            var d = IncrementalDecoder(encoding: .utf8)
            let first = d.feed(Data(emoji[..<cut]))
            XCTAssertTrue(first.isEmpty, "cut \(cut)")
            XCTAssertEqual(text(d.feed(Data(emoji[cut...]))), "🙂", "cut \(cut)")
        }
    }

    func testThreeByteCharacterSplit() {
        var d = IncrementalDecoder(encoding: .utf8BOM)
        let euro = [UInt8]("€".utf8)  // E2 82 AC
        XCTAssertTrue(d.feed(Data(euro[..<2])).isEmpty)
        XCTAssertEqual(text(d.feed(Data([euro[2]]))), "€")
    }

    func testInvalidBytesAreNotHeldBack() {
        var d = IncrementalDecoder(encoding: .utf8)
        XCTAssertEqual(d.feed(Data([0x41, 0xFF])), Data([0x41, 0xFF]))
        XCTAssertTrue(d.pending.isEmpty)
    }

    func testEmptyFeed() {
        var d = IncrementalDecoder(encoding: .utf8)
        XCTAssertTrue(d.feed(Data()).isEmpty)
    }

    func testResetDropsPendingBytes() {
        var d = IncrementalDecoder(encoding: .utf8)
        _ = d.feed(Data([0xC3]))
        d.reset()
        XCTAssertTrue(d.pending.isEmpty)
    }

    // MARK: UTF-16

    func testUTF16LEOddByteIsHeldBack() {
        var d = IncrementalDecoder(encoding: .utf16LE)
        XCTAssertEqual(text(d.feed(Data([0x68, 0x00, 0x69]))), "h")
        XCTAssertEqual(text(d.feed(Data([0x00]))), "i")
    }

    func testUTF16BEHebrew() {
        var d = IncrementalDecoder(encoding: .utf16BE)
        XCTAssertEqual(text(d.feed("שלום".data(using: .utf16BigEndian)!)), "שלום")
    }

    func testUTF16SurrogatePairSplitAcrossWrites() {
        var d = IncrementalDecoder(encoding: .utf16LE)
        let bytes = [UInt8]("🙂".data(using: .utf16LittleEndian)!)  // 4 bytes: high + low surrogate
        XCTAssertTrue(d.feed(Data(bytes[..<2])).isEmpty, "a lone high surrogate must wait")
        XCTAssertEqual(text(d.feed(Data(bytes[2...]))), "🙂")
    }

    // MARK: ANSI

    func testANSIIsWindows1252() {
        var d = IncrementalDecoder(encoding: .ansi)
        XCTAssertEqual(text(d.feed(Data([0x63, 0x61, 0x66, 0xE9, 0x80]))), "café€")
    }
}

/// Monitoring through a real Scintilla editor and a real file on disk.
final class EditorTabMonitoringTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadTail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("app.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ text: String) throws { try append(Data(text.utf8)) }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func monitoredTab(_ initial: String) throws -> EditorTab {
        try Data(initial.utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        try tab.startMonitoring(pollInterval: 60)  // tests drive checks directly
        addTeardownBlock { tab.detach() }
        return tab
    }

    private func text(_ tab: EditorTab) -> String { String(decoding: tab.editor.utf8Bytes(), as: UTF8.self) }
    private func caretAtEnd(_ tab: EditorTab) -> Bool { tab.editor.send(SCI_GETCURRENTPOS) == tab.editor.send(SCI_GETLENGTH) }

    // MARK: Starting and stopping

    func testStartingMakesTheTabReadOnlyAtTheEndAndMarksTheLabel() throws {
        let tab = try monitoredTab("one\ntwo\n")
        XCTAssertTrue(tab.isMonitoring)
        XCTAssertEqual(tab.editor.send(SCI_GETREADONLY), 1)
        XCTAssertTrue(caretAtEnd(tab))
        XCTAssertFalse(tab.isModified)
        XCTAssertTrue(tab.tabLabel.hasPrefix("👁 "))
    }

    func testStoppingMakesTheTabEditableAgain() throws {
        let tab = try monitoredTab("x")
        tab.stopMonitoring()
        XCTAssertFalse(tab.isMonitoring)
        XCTAssertEqual(tab.editor.send(SCI_GETREADONLY), 0)
        XCTAssertEqual(tab.tabLabel, "app.log")
    }

    func testRefusesToStartWithUnsavedEdits() throws {
        try Data("x".utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        tab.editor.send(SCI_APPENDTEXT, 1, string: "y")
        XCTAssertThrowsError(try tab.startMonitoring())
        XCTAssertFalse(tab.isMonitoring)
    }

    func testStartingRereadsTheFileFromDisk() throws {
        try Data("old".utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        try append(" and new")  // changed after it was opened
        try tab.startMonitoring(pollInterval: 60)
        addTeardownBlock { tab.detach() }
        XCTAssertEqual(text(tab), "old and new")
    }

    // MARK: Following a growing file

    func testAppendedLinesAreAddedAndFollowed() throws {
        let tab = try monitoredTab("line 1\n")
        try append("line 2\nline 3\n")
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "line 1\nline 2\nline 3\n")
        XCTAssertTrue(caretAtEnd(tab), "the view follows the end")
        XCTAssertFalse(tab.isModified, "appended text is not an edit")
        XCTAssertEqual(tab.editor.send(SCI_CANUNDO), 0, "and leaves no undo history")
    }

    func testScrollingUpPausesFollowing() throws {
        let tab = try monitoredTab("a\nb\nc\n")
        tab.editor.send(SCI_GOTOPOS, 0)
        try append("d\n")
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "a\nb\nc\nd\n")
        XCTAssertEqual(tab.editor.send(SCI_GETCURRENTPOS), 0, "caret stays where the reader is")
    }

    func testNothingNewMeansNoChange() throws {
        let tab = try monitoredTab("same")
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "same")
    }

    func testCharacterSplitAcrossTwoWritesArrivesWhole() throws {
        let tab = try monitoredTab("")
        let shalom = [UInt8]("שלום\n".utf8)
        try append(Data(shalom[..<3]))  // ש + first byte of ל
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "ש")
        try append(Data(shalom[3...]))
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "שלום\n")
    }

    func testManyAppendsInARow() throws {
        let tab = try monitoredTab("")
        var expected = ""
        for i in 1...50 {
            let line = "entry \(i)\n"
            expected += line
            try append(line)
            if i % 7 == 0 { tab.checkMonitoredFile() }
        }
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), expected)
    }

    // MARK: Rotation, truncation, deletion

    func testTruncationRereadsFromTheStart() throws {
        let tab = try monitoredTab("a long first generation\n")
        try Data("new\n".utf8).write(to: url)  // same inode, shorter
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "new\n")
        XCTAssertTrue(caretAtEnd(tab))
    }

    func testRotationRenameAndRecreateIsFollowed() throws {
        let tab = try monitoredTab("generation 1\n")
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("app.log.1"))
        try Data("generation 2\n".utf8).write(to: url)
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "generation 2\n")
        try append("more\n")
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "generation 2\nmore\n")
    }

    func testDeletedFileKeepsItsTextAndIsPickedUpWhenItReturns() throws {
        let tab = try monitoredTab("before\n")
        try FileManager.default.removeItem(at: url)
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "before\n", "the last content stays visible")
        XCTAssertTrue(tab.isMonitoring)
        try Data("after\n".utf8).write(to: url)
        tab.checkMonitoredFile()
        XCTAssertEqual(text(tab), "after\n")
    }

    // MARK: Never writing to a monitored file

    func testSaveDoesNotWriteAMonitoredFile() throws {
        let tab = try monitoredTab("one\n")
        try append("two\n")  // not yet read by the tab
        var reported: Bool?
        tab.save { reported = $0 }
        XCTAssertEqual(reported, true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n", "the writer's data is untouched")
    }

    func testConversionsAreIgnoredWhileMonitoring() throws {
        let tab = try monitoredTab("a\r\nb")
        tab.convertLineEndings(to: .lf)
        try tab.convertEncoding(to: .utf16LE)
        XCTAssertEqual(text(tab), "a\r\nb")
        XCTAssertEqual(tab.encoding, .utf8)
    }

    func testTypingIsBlockedWhileMonitoring() throws {
        let tab = try monitoredTab("ro")
        tab.editor.send(SCI_APPENDTEXT, 1, string: "x")  // Scintilla refuses on a read-only document
        XCTAssertEqual(text(tab), "ro")
    }

    // MARK: The live watcher

    func testTheWatcherPicksUpAppendsByItself() throws {
        try Data("start\n".utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        try tab.startMonitoring(pollInterval: 0.2)
        addTeardownBlock { tab.detach() }
        try append("live\n")
        let deadline = Date().addingTimeInterval(5)
        while text(tab) != "start\nlive\n", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(text(tab), "start\nlive\n")
    }
}

/// Monitoring state in the session and on the tab.
final class MonitoringSessionTests: XCTestCase {
    func testOlderSessionsWithoutTheFlagStillLoad() throws {
        let json = #"{"version":1,"activeIndex":0,"documents":[{"path":"/tmp/a.log","caretPosition":3,"firstVisibleLine":0}]}"#
        let state = try XCTUnwrap(SessionState.decoded(from: Data(json.utf8)))
        XCTAssertEqual(state.documents.first?.isMonitoring, false)
        XCTAssertEqual(state.documents.first?.caretPosition, 3)
    }

    func testMonitoringFlagRoundTrips() throws {
        let state = SessionState(documents: [.init(path: "/tmp/a.log", isMonitoring: true)])
        XCTAssertEqual(SessionState.decoded(from: try state.encoded()), state)
    }

    func testTabLabels() {
        XCTAssertEqual(TabTitle.tabLabel(displayName: "a.log", isModified: false, isMonitoring: true), "👁 a.log")
        XCTAssertEqual(TabTitle.tabLabel(displayName: "a.log", isModified: true, isMonitoring: true), "• 👁 a.log")
        XCTAssertEqual(TabTitle.tabLabel(displayName: "a.log", isModified: false), "a.log")
    }
}
