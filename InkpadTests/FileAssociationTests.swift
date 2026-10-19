import XCTest
@testable import Inkpad

/// MAC-51: Settings › File Association, against a fake LaunchServices.
final class FileAssociationTests: XCTestCase {
    /// Extension (without the dot) → default app's bundle identifier.
    final class FakeStore: DefaultAppStore {
        var defaults: [String: String] = [:]
        var apps: [String: URL] = [
            "com.apple.TextEdit": URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            "app.inkpad.Inkpad": URL(fileURLWithPath: "/Applications/Inkpad++.app"),
        ]
        var failNext: Error?
        private(set) var calls: [(app: URL, ext: String)] = []

        func defaultApp(forExtension ext: String) -> String? { defaults[ext] }
        func setDefaultApp(_ appURL: URL, forExtension ext: String, completion: @escaping (Error?) -> Void) {
            calls.append((appURL, ext))
            if let error = failNext { failNext = nil; completion(error); return }
            defaults[ext] = apps.first { $0.value == appURL }?.key
            completion(nil)
        }
        func appURL(bundleIdentifier: String) -> URL? { apps[bundleIdentifier] }
    }

    private var suite: String!
    private var userDefaults: UserDefaults!
    private var store: FakeStore!
    private var model: FileAssociation!

    override func setUp() {
        suite = "FileAssociationTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suite)
        store = FakeStore()
        model = FileAssociation(store: store, defaults: userDefaults, appIdentifier: "app.inkpad.Inkpad",
                                appURL: URL(fileURLWithPath: "/Applications/Inkpad++.app"))
    }

    override func tearDown() { userDefaults.removePersistentDomain(forName: suite) }

    private func register(_ ext: String) -> Error? {
        var result: Error?
        model.register(ext) { result = $0 }
        return result
    }

    private func unregister(_ ext: String) -> Error? {
        var result: Error?
        model.unregister(ext) { result = $0 }
        return result
    }

    // MARK: - upstream's table

    func testTheCategoriesAreUpstreamOnes() {
        let names = FileAssociation.categories.map(\.name)
        XCTAssertEqual(names, ["Text", "ms ini/inf", "c, c++, objc", "java, c#, pascal", "web script",
                               "public script", "property script", "fortran, TeX, SQL", "misc", "customize"])
        XCTAssertEqual(FileAssociation.categories[0].extensions, [".txt", ".log"])
        XCTAssertEqual(FileAssociation.categories[2].extensions.count, 15)
        XCTAssertEqual(FileAssociation.categories[4].extensions.count, 27)
        XCTAssertEqual(FileAssociation.categories[5].extensions.last, ".py")
        XCTAssertEqual(FileAssociation.categories[8].extensions, [".nfo", ".mak"])
        XCTAssertTrue(FileAssociation.categories.last!.extensions.isEmpty)
        let all = FileAssociation.categories.flatMap(\.extensions)
        XCTAssertEqual(all.count, Set(all).count, "no extension in two categories")
    }

    func testNormalize() {
        XCTAssertEqual(FileAssociation.normalize(".TXT"), ".txt")
        XCTAssertEqual(FileAssociation.normalize("txt"), ".txt")
        XCTAssertEqual(FileAssociation.normalize("  .c++ "), ".c++")
        XCTAssertEqual(FileAssociation.normalize("my_ext-2"), ".my_ext-2")
        XCTAssertNil(FileAssociation.normalize(""))
        XCTAssertNil(FileAssociation.normalize("."))
        XCTAssertNil(FileAssociation.normalize("a.b"))
        XCTAssertNil(FileAssociation.normalize("a b"))
        XCTAssertNil(FileAssociation.normalize("../x"))
        XCTAssertNil(FileAssociation.normalize(".שלום"))
        XCTAssertNil(FileAssociation.normalize(String(repeating: "x", count: 33)))
    }

    // MARK: - Registering

    func testRegisteringMakesInkpadTheDefaultAndRemembersThePreviousApp() {
        store.defaults["txt"] = "com.microsoft.VSCode"
        XCTAssertNil(register(".txt"))
        XCTAssertEqual(store.defaults["txt"], "app.inkpad.Inkpad")
        XCTAssertEqual(store.calls.last?.app.lastPathComponent, "Inkpad++.app")
        XCTAssertEqual(model.previousApps, [".txt": "com.microsoft.VSCode"])
        XCTAssertEqual(model.registered, [".txt"])
        XCTAssertEqual(model.available(in: "Text"), [".log"], "a registered extension leaves the middle list")
    }

    func testRegisteringTwiceKeepsTheFirstPreviousApp() {
        store.defaults["log"] = "com.apple.TextEdit"
        XCTAssertNil(register(".log"))
        XCTAssertNil(register(".log"))
        XCTAssertEqual(model.previousApps[".log"], "com.apple.TextEdit", "not overwritten with Inkpad++ itself")
    }

    func testTheRegisteredListIsWhatLaunchServicesSays() {
        store.defaults["py"] = "app.inkpad.Inkpad"  // set in Finder's Get Info
        store.defaults["c"] = "com.microsoft.VSCode"
        XCTAssertEqual(model.registered, [".py"])
        XCTAssertFalse(model.available(in: "public script").contains(".py"))
        XCTAssertTrue(model.available(in: "c, c++, objc").contains(".c"))
    }

    func testACustomExtensionIsRemembered() {
        XCTAssertNil(register("MyLog"))
        XCTAssertEqual(model.customExtensions, [".mylog"])
        XCTAssertEqual(model.registered, [".mylog"])
        XCTAssertNil(register(".mylog"))
        XCTAssertEqual(model.customExtensions, [".mylog"], "remembered once")
        XCTAssertNil(register(".txt"))
        XCTAssertEqual(model.customExtensions, [".mylog"], "a category's extension is not custom")
        XCTAssertTrue(model.available(in: "customize").isEmpty)
    }

    func testAFailedRegistrationRecordsNothing() {
        store.defaults["ini"] = "com.apple.TextEdit"
        store.failNext = FileAssociation.Failure.unknownType("ini")
        XCTAssertEqual(register(".ini") as? FileAssociation.Failure, .unknownType("ini"))
        XCTAssertTrue(model.previousApps.isEmpty)
        XCTAssertTrue(model.registered.isEmpty)
        XCTAssertEqual(register("a b") as? FileAssociation.Failure, .invalidExtension("a b"))
    }

    // MARK: - Unregistering

    func testUnregisteringGivesTheExtensionBack() {
        store.defaults["html"] = "com.microsoft.VSCode"
        XCTAssertNil(register(".html"))
        XCTAssertNil(unregister(".html"))
        XCTAssertEqual(store.defaults["html"], "com.microsoft.VSCode")
        XCTAssertTrue(model.previousApps.isEmpty)
        XCTAssertTrue(model.registered.isEmpty)
    }

    func testUnregisteringFallsBackToTextEdit() {
        XCTAssertNil(register(".sql"))  // nothing had it before
        XCTAssertNil(unregister(".sql"))
        XCTAssertEqual(store.defaults["sql"], "com.apple.TextEdit")

        store.defaults["css"] = "com.microsoft.VSCode"
        XCTAssertNil(register(".css"))
        store.apps["com.microsoft.VSCode"] = nil  // uninstalled since
        XCTAssertNil(unregister(".css"))
        XCTAssertEqual(store.defaults["css"], "com.apple.TextEdit")
    }

    func testUnregisteringWithNoAppLeftFails() {
        XCTAssertNil(register(".nfo"))
        store.apps["com.apple.TextEdit"] = nil
        XCTAssertEqual(unregister(".nfo") as? FileAssociation.Failure, .noAppToRestore(".nfo"))
        XCTAssertEqual(store.defaults["nfo"], "app.inkpad.Inkpad", "left as it was")
    }

    // MARK: - The page

    func testThePageFollowsUpstreamLists() {
        store.defaults["log"] = "app.inkpad.Inkpad"
        let pane = FileAssociationPane(model: model)
        XCTAssertEqual(pane.selectedCategory, "Text")
        XCTAssertEqual(pane.available, [".txt"])
        XCTAssertEqual(pane.registered, [".log"])
        XCTAssertFalse(pane.registerButton.isEnabled, "nothing selected")

        pane.availableTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(pane.registerButton.isEnabled)
        pane.registerClicked(nil)
        XCTAssertEqual(pane.registered, [".log", ".txt"])
        XCTAssertEqual(pane.available, [])

        pane.registeredTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.unregisterClicked(nil)
        XCTAssertEqual(pane.registered, [".txt"])
        XCTAssertEqual(pane.available, [".log"])
    }

    func testTheCustomizeCategoryTakesATypedExtension() {
        let pane = FileAssociationPane(model: model)
        pane.categoryTable.selectRowIndexes(IndexSet(integer: FileAssociation.categories.count - 1), byExtendingSelection: false)
        XCTAssertTrue(pane.isCustomize)
        XCTAssertFalse(pane.customField.isHidden)
        XCTAssertTrue(pane.availableTable.enclosingScrollView?.isHidden == true)
        pane.customField.stringValue = "a b"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(pane.registerButton.isEnabled)
        pane.customField.stringValue = ".conf"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(pane.registerButton.isEnabled)
        pane.registerClicked(nil)
        XCTAssertEqual(pane.registered, [".conf"])
        XCTAssertEqual(pane.customField.stringValue, "")
    }

    func testErrorsReachThePage() {
        let pane = FileAssociationPane(model: model)
        var reported: Error?
        pane.onError = { reported = $0 }
        store.failNext = FileAssociation.Failure.unknownType("txt")
        pane.availableTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.registerClicked(nil)
        XCTAssertEqual(reported as? FileAssociation.Failure, .unknownType("txt"))
        XCTAssertTrue(pane.registered.isEmpty)
    }
}
