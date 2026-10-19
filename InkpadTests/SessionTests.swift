import XCTest
@testable import Inkpad

/// The stored session: what survives a quit, and what happens when it no longer matches the disk.
final class SessionStateTests: XCTestCase {
    private func state(_ paths: [String], active: Int = 0) -> SessionState {
        SessionState(documents: paths.map { SessionState.Document(path: $0) }, activeIndex: active)
    }

    func testRoundTripsThroughJSON() throws {
        let original = SessionState(
            documents: [
                .init(path: "/tmp/a.swift", caretPosition: 120, firstVisibleLine: 7),
                .init(path: "/tmp/b.py", caretPosition: 0, firstVisibleLine: 0),
            ],
            activeIndex: 1)
        let decoded = SessionState.decoded(from: try original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testNewDocumentsDefaultToTheTopOfTheFile() {
        let document = SessionState.Document(path: "/tmp/a.txt")
        XCTAssertEqual(document.caretPosition, 0)
        XCTAssertEqual(document.firstVisibleLine, 0)
    }

    func testMalformedDataIsNotASession() {
        XCTAssertNil(SessionState.decoded(from: Data("not json".utf8)))
        XCTAssertNil(SessionState.decoded(from: Data()))
        XCTAssertNil(SessionState.decoded(from: Data(#"{"documents":[]}"#.utf8)),
                     "a payload without a version is not a session this build wrote")
    }

    func testASessionFromAnotherVersionIsIgnored() throws {
        var future = state(["/tmp/a.txt"])
        future.version = SessionState.currentVersion + 1
        XCTAssertNil(SessionState.decoded(from: try future.encoded()),
                     "an unknown layout must cost the tabs, not the launch")
    }

    // MARK: files that went away

    func testDocumentsWhoseFileIsGoneAreDropped() {
        let filtered = state(["/tmp/gone.txt", "/tmp/here.txt"], active: 1)
            .filtered { $0 == "/tmp/here.txt" }
        XCTAssertEqual(filtered.documents.map(\.path), ["/tmp/here.txt"])
        XCTAssertEqual(filtered.activeIndex, 0)
    }

    func testTheActiveDocumentStaysActiveWhenEarlierOnesAreDropped() {
        let filtered = state(["/a", "/b", "/c"], active: 2).filtered { $0 != "/a" }
        XCTAssertEqual(filtered.documents.map(\.path), ["/b", "/c"])
        XCTAssertEqual(filtered.activeIndex, 1, "/c must still be the active document")
    }

    func testADroppedActiveDocumentLandsOnItsNeighbour() {
        let filtered = state(["/a", "/b", "/c"], active: 1).filtered { $0 != "/b" }
        XCTAssertEqual(filtered.documents.map(\.path), ["/a", "/c"])
        XCTAssertEqual(filtered.activeIndex, 1, "the document that took its place")
    }

    func testADroppedLastActiveDocumentClampsToTheEnd() {
        let filtered = state(["/a", "/b"], active: 1).filtered { $0 != "/b" }
        XCTAssertEqual(filtered.documents.map(\.path), ["/a"])
        XCTAssertEqual(filtered.activeIndex, 0)
    }

    func testASessionWhoseFilesAreAllGoneIsEmpty() {
        let filtered = state(["/a", "/b"], active: 1).filtered { _ in false }
        XCTAssertTrue(filtered.isEmpty)
        XCTAssertEqual(filtered.activeIndex, 0)
    }

    func testAnEmptySessionIsEmpty() {
        XCTAssertTrue(SessionState().isEmpty)
    }
}

/// Reading and writing the session file.
final class SessionStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-test-\(UUID().uuidString)/session.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testSavingCreatesTheDirectoryAndLoadsBack() {
        let state = SessionState(
            documents: [.init(path: "/tmp/a.txt", caretPosition: 9, firstVisibleLine: 2)],
            activeIndex: 0)
        XCTAssertTrue(SessionStore.save(state, to: url))
        XCTAssertEqual(SessionStore.load(from: url), state)
    }

    func testLoadingAMissingFileIsNoSessionRatherThanAnError() {
        XCTAssertNil(SessionStore.load(from: url))
    }

    func testLoadingACorruptFileIsNoSession() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(to: url)
        XCTAssertNil(SessionStore.load(from: url))
    }

    func testSavingOverAnExistingSessionReplacesIt() {
        SessionStore.save(SessionState(documents: [.init(path: "/tmp/old.txt")]), to: url)
        SessionStore.save(SessionState(documents: [.init(path: "/tmp/new.txt")]), to: url)
        XCTAssertEqual(SessionStore.load(from: url)?.documents.map(\.path), ["/tmp/new.txt"])
    }
}
