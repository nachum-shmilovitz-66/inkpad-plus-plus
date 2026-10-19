import XCTest
@testable import Inkpad

/// MAC-43: the Shortcut Mapper and the stored shortcut changes.
final class ShortcutMapperTests: XCTestCase {
    private let suite = "app.inkpad.Inkpad.tests.shortcuts"
    private var defaults: UserDefaults!
    private var macroURL: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        macroURL = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadShortcuts-\(UUID().uuidString)/macros.json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: macroURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func menu() -> NSMenu {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        let join = NSMenuItem(title: "Join Lines", action: #selector(MainWindowController.lineOperation(_:)), keyEquivalent: "j")
        join.tag = 5
        edit.addItem(join)
        let split = NSMenuItem(title: "Split Lines", action: #selector(MainWindowController.lineOperation(_:)), keyEquivalent: "i")
        split.tag = 4
        edit.addItem(split)
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = edit
        main.addItem(top)
        return main
    }

    func testOverridesApplyAndSurviveAndReset() {
        let store = ShortcutStore(defaults: defaults)
        let m = menu()
        store.apply(to: m)
        let id = "lineOperation:#5"
        store.set(.init(key: "k", modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue), for: id)
        store.apply(to: m)
        let join = m.items[0].submenu!.items[0]
        XCTAssertEqual(join.keyEquivalent, "k")
        XCTAssertEqual(join.keyEquivalentModifierMask, [.command, .control])
        let fresh = menu()
        ShortcutStore(defaults: defaults).apply(to: fresh)
        XCTAssertEqual(fresh.items[0].submenu!.items[0].keyEquivalent, "k", "kept across launches")
        store.reset(id)
        store.apply(to: m)
        XCTAssertEqual(join.keyEquivalent, "j", "back to the built-in shortcut")
    }

    func testTheMapperListsFiltersModifiesAndClears() {
        let m = menu()
        let store = ShortcutStore(defaults: defaults)
        store.apply(to: m)
        let mapper = ShortcutMapperController(store: store, macros: MacroStore(url: macroURL), menuProvider: { m })
        XCTAssertEqual(mapper.rows.map(\.name), ["Join Lines", "Split Lines"])
        XCTAssertEqual(mapper.rows.first?.category, "Edit")
        XCTAssertEqual(mapper.rows.first?.shortcutText, "⌘J")
        mapper.filterField.stringValue = "split"
        mapper.reload()
        XCTAssertEqual(mapper.rows.map(\.name), ["Split Lines"])
        mapper.filterField.stringValue = ""
        mapper.reload()

        mapper.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        mapper.askShortcut = { _, editable, _, _, completion in
            XCTAssertFalse(editable, "a menu command's name is not editable")
            completion(("Join Lines", "i", [.command]))
        }
        mapper.modify()
        XCTAssertEqual(mapper.rows.first?.shortcutText, "⌘I")
        mapper.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        mapper.updateConflict()
        XCTAssertTrue(mapper.conflictLabel.stringValue.contains("CONFLICT FOUND!"), "⌘I is Split Lines too")
        mapper.clear()
        XCTAssertEqual(mapper.rows.first?.shortcutText, "")
        mapper.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        mapper.resetToDefault()
        XCTAssertEqual(mapper.rows.first?.shortcutText, "⌘J")
    }

    func testMacrosCanBeRenamedReassignedAndDeleted() {
        let macros = MacroStore(url: macroURL)
        let mapper = ShortcutMapperController(store: ShortcutStore(defaults: defaults), macros: macros, menuProvider: { NSMenu() })
        mapper.select(.macros)
        XCTAssertEqual(mapper.rows.map(\.name), ["Trim Trailing Space and Save"])
        XCTAssertFalse(mapper.deleteButton.isHidden)
        mapper.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        mapper.askShortcut = { _, editable, _, _, completion in
            XCTAssertTrue(editable)
            completion(("Trim and Save", "t", [.command, .control]))
        }
        mapper.modify()
        XCTAssertEqual(macros.macros.first?.name, "Trim and Save")
        XCTAssertEqual(macros.macros.first?.key, "t")
        mapper.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        mapper.deleteMacro()
        XCTAssertTrue(macros.macros.isEmpty)
    }

    func testTheAppsMenusAreListed() {
        let mapper = ShortcutMapperController(store: ShortcutStore(defaults: defaults), macros: MacroStore(url: macroURL))
        XCTAssertTrue(mapper.rows.contains { $0.name == "Find…" && $0.shortcutText == "⌘F" })
        XCTAssertTrue(mapper.rows.contains { $0.category.hasPrefix("Edit › Line Operations") })
        XCTAssertFalse(mapper.rows.contains { $0.category.hasPrefix("Macro") }, "macros have their own page")
    }
}
