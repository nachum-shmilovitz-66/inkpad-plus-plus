import XCTest
@testable import Inkpad

/// MAC-78: settings and the support folder carry over from the old name, once.
final class LegacyMigrationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUpWithError() throws {
        suite = "app.inkpad.Inkpad.tests.legacy.\(UUID().uuidString)"  // a throwaway suite only
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheOldDomainOfEachBuild() {
        XCTAssertEqual(LegacyMigration.legacyDomain(for: "app.inkpad.Inkpad"), "app.macpad.MacPad")
        XCTAssertEqual(LegacyMigration.legacyDomain(for: "app.inkpad.Inkpad.debug"), "app.macpad.MacPad.debug")
        XCTAssertNil(LegacyMigration.legacyDomain(for: "com.example.other"))
    }

    func testKeysNamedAfterTheAppAreRenamed() {
        XCTAssertEqual(LegacyMigration.renamedKey("NSWindow Frame MacPad++ Main Window"), "NSWindow Frame Inkpad++ Main Window")
        XCTAssertEqual(LegacyMigration.renamedKey("NSToolbar Configuration MacPadMainToolbar"), "NSToolbar Configuration InkpadMainToolbar")
        XCTAssertEqual(LegacyMigration.renamedKey("Preferences"), "Preferences")
    }

    func testSettingsAreCopiedOnceAndNewOnesWin() {
        defaults.set("new", forKey: "Theme")
        let old: [String: Any] = ["Preferences": Data([1, 2]), "Theme": "old", "NSWindow Frame MacPad++ Main Window": "0 0 10 10"]
        XCTAssertEqual(LegacyMigration.migrateDefaults(from: old, into: defaults), 2)
        XCTAssertEqual(defaults.data(forKey: "Preferences"), Data([1, 2]))
        XCTAssertEqual(defaults.string(forKey: "Theme"), "new", "the new install's own value wins")
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame Inkpad++ Main Window"), "0 0 10 10")
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))

        XCTAssertEqual(LegacyMigration.migrateDefaults(from: ["Later": 1], into: defaults), 0, "only once")
        XCTAssertNil(defaults.object(forKey: "Later"))
    }

    func testNoOldSettingsStillMarksItDone() {
        XCTAssertEqual(LegacyMigration.migrateDefaults(from: nil, into: defaults), 0)
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
    }

    func testTheSupportFolderIsCopiedWhileTheNewOneIsMissing() throws {
        let old = folder.appendingPathComponent(LegacyMigration.oldFolderName)
        let new = folder.appendingPathComponent("Inkpad++")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("macros.json"))
        XCTAssertTrue(LegacyMigration.migrateSupportFolder(old: old, new: new))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("macros.json")), Data("{}".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("themes").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the old folder is left as a backup")

        try Data("[]".utf8).write(to: old.appendingPathComponent("macros.json"))
        XCTAssertFalse(LegacyMigration.migrateSupportFolder(old: old, new: new), "an existing new folder is never overwritten")
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("macros.json")), Data("{}".utf8))
    }

    func testNothingToCopyWithoutAnOldFolder() {
        XCTAssertFalse(LegacyMigration.migrateSupportFolder(old: folder.appendingPathComponent("none"), new: folder.appendingPathComponent("Inkpad++")))
    }
}
