import XCTest
@testable import MacPad

/// The recent-files list: order, de-duplication and capacity.
final class RecentFilesTests: XCTestCase {
    func testMostRecentComesFirst() {
        var recent = RecentFiles()
        recent.record("/a")
        recent.record("/b")
        XCTAssertEqual(recent.paths, ["/b", "/a"])
    }

    func testReopeningAFileMovesItToTheFrontWithoutDuplicating() {
        var recent = RecentFiles(paths: ["/a", "/b", "/c"])
        recent.record("/c")
        XCTAssertEqual(recent.paths, ["/c", "/a", "/b"])
    }

    func testTheListIsCappedAndDropsTheOldest() {
        var recent = RecentFiles()
        for index in 1...(RecentFiles.capacity + 3) { recent.record("/file\(index)") }
        XCTAssertEqual(recent.paths.count, RecentFiles.capacity)
        XCTAssertEqual(recent.paths.first, "/file\(RecentFiles.capacity + 3)")
        XCTAssertFalse(recent.paths.contains("/file1"), "the oldest entries fell off")
    }

    func testInitialisingFromStorageDropsDuplicatesEmptiesAndOverflow() {
        let stored = ["/a", "", "/b", "/a"] + (1...RecentFiles.capacity).map { "/x\($0)" }
        let recent = RecentFiles(paths: stored)
        XCTAssertEqual(recent.paths.count, RecentFiles.capacity)
        XCTAssertEqual(recent.paths.prefix(2).map { $0 }, ["/a", "/b"])
        XCTAssertFalse(recent.paths.contains(""))
    }

    func testEmptyPathsAreIgnored() {
        var recent = RecentFiles()
        recent.record("")
        XCTAssertTrue(recent.isEmpty)
    }

    func testRemovingAnEntry() {
        var recent = RecentFiles(paths: ["/a", "/b"])
        recent.remove("/a")
        recent.remove("/not-there")
        XCTAssertEqual(recent.paths, ["/b"])
    }

    func testClearing() {
        var recent = RecentFiles(paths: ["/a", "/b"])
        recent.clear()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(recent.urls, [])
    }

    func testURLsMatchThePaths() {
        XCTAssertEqual(RecentFiles(paths: ["/tmp/a.txt"]).urls, [URL(fileURLWithPath: "/tmp/a.txt")])
    }
}

/// Persistence through user defaults.
final class RecentFilesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "RecentFilesStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store() -> RecentFilesStore {
        RecentFilesStore(defaults: defaults, key: "RecentFiles")
    }

    func testRecordedFilesSurviveANewStore() {
        let first = store()
        first.record(URL(fileURLWithPath: "/tmp/a.txt"))
        first.record(URL(fileURLWithPath: "/tmp/b.txt"))
        XCTAssertEqual(store().files.paths, ["/tmp/b.txt", "/tmp/a.txt"])
    }

    func testPathsAreStandardisedSoTheSameFileIsNotListedTwice() {
        let store = store()
        store.record(URL(fileURLWithPath: "/tmp/a.txt"))
        store.record(URL(fileURLWithPath: "/tmp/./a.txt"))
        XCTAssertEqual(store.files.paths, ["/tmp/a.txt"])
    }

    func testRemovingAndClearingPersist() {
        let store = store()
        store.record(URL(fileURLWithPath: "/tmp/a.txt"))
        store.record(URL(fileURLWithPath: "/tmp/b.txt"))
        store.remove(URL(fileURLWithPath: "/tmp/b.txt"))
        XCTAssertEqual(self.store().files.paths, ["/tmp/a.txt"])
        store.clear()
        XCTAssertTrue(self.store().files.isEmpty)
    }

    func testAnEmptyDefaultsStoreStartsEmpty() {
        XCTAssertTrue(store().files.isEmpty)
    }
}
