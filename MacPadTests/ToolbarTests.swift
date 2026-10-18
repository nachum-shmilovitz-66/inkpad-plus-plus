import XCTest
@testable import MacPad

/// MAC-69: Notepad++'s toolbar — its buttons in its order, SF Symbols or its Fluent icons, and
/// each button showing its menu command's state.
final class ToolbarTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var vendorIcons: URL { repo.appendingPathComponent("vendor/notepad-plus-plus/PowerEditor/src/icons") }

    override func tearDown() {
        Preferences.update { $0 = Preferences() }
        super.tearDown()
    }

    /// Notepad++'s `toolBarIcons[]`: its command ids, a new group at each `0` (separator) entry.
    private func notepadPlusPlusGroups() throws -> [[String]] {
        let source = try String(contentsOf: repo.appendingPathComponent("vendor/notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "toolBarIcons[]{"))
        let end = try XCTUnwrap(source.range(of: "};", range: start.upperBound..<source.endIndex))
        var groups: [[String]] = [[]]
        for line in source[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("{"), let id = entry.dropFirst().split(separator: ",").first else { continue }
            if id == "0" { groups.append([]) } else { groups[groups.count - 1].append(String(id)) }
        }
        return groups
    }

    // MARK: - Layout

    func testTheButtonsAreNotepadPlusPlussInItsOrderAndGroups() throws {
        XCTAssertEqual(ToolbarLayout.groups.map { $0.map(\.nppCommand) }, try notepadPlusPlusGroups())
    }

    func testCommandsMacPadDoesNotHaveYetAreLeftOut() {
        let missing = ToolbarLayout.groups.joined().filter { $0.action == nil }.map(\.label)
        XCTAssertEqual(missing, ["Save All", "Close All", "Print", "Show Indent Guide", "User Defined Language", "Document List"])
        XCTAssertFalse(ToolbarLayout.defaultIdentifiers.contains(where: { $0.rawValue == "npp.print" }))
        XCTAssertNil(MainToolbar(iconSet: .sfSymbols).toolbar(NSToolbar(), itemForItemIdentifier: .init("npp.print"),
                                                               willBeInsertedIntoToolbar: true))
    }

    func testEveryButtonRunsTheSameCommandAsItsMenuItem() {
        var actions = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action { actions.insert(NSStringFromSelector(action)) }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(MainMenu.build())
        for button in ToolbarLayout.available.joined() {
            XCTAssertTrue(actions.contains(NSStringFromSelector(button.action!)), "\(button.label) has no menu item")
        }
    }

    func testGroupsAreSeparatedBySpaces() {
        let ids = ToolbarLayout.defaultIdentifiers
        XCTAssertNotEqual(ids.first, .space)
        XCTAssertNotEqual(ids.last, .space)
        XCTAssertEqual(ids.filter { $0 == .space }.count, ToolbarLayout.available.count - 1)
        XCTAssertEqual(ids.filter { $0 != .space }, ToolbarLayout.available.joined().map(\.identifier))
        XCTAssertEqual(Set(ids.filter { $0 != .space }).count, ids.filter { $0 != .space }.count, "identifiers are unique")
    }

    // MARK: - Icons

    func testEverySymbolExists() {
        for button in ToolbarLayout.groups.joined() {
            XCTAssertNotNil(NSImage(systemSymbolName: button.symbol, accessibilityDescription: nil), "\(button.label): \(button.symbol)")
        }
    }

    func testEveryButtonHasNotepadPlusPlussFluentIconsInAllFourVersions() {
        for button in ToolbarLayout.groups.joined() {
            for look in ["light", "dark"] {
                for style in ["regular", "filled"] {
                    let path = "\(look)/toolbar/\(style)/\(button.fluentStem)_off.ico"
                    XCTAssertTrue(FileManager.default.fileExists(atPath: vendorIcons.appendingPathComponent(path).path), path)
                }
            }
        }
    }

    func testTheAppBundlesTheFluentIcons() throws {
        for button in ToolbarLayout.available.joined() {
            for dark in [false, true] {
                for filled in [false, true] {
                    let url = try XCTUnwrap(ToolbarIcons.fluentURL(stem: button.fluentStem, dark: dark, filled: filled))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
                }
            }
        }
    }

    func testTheIconSetPicksTheImage() throws {
        let wrap = try XCTUnwrap(ToolbarLayout.groups.joined().first { $0.fluentStem == "wrap" })
        let symbol = try XCTUnwrap(ToolbarIcons.image(for: wrap, iconSet: .sfSymbols))
        XCTAssertTrue(symbol.isTemplate, "SF Symbols tint with the system")
        let fluent = try XCTUnwrap(ToolbarIcons.image(for: wrap, iconSet: .fluent))
        XCTAssertFalse(fluent.isTemplate, "Fluent icons keep Notepad++'s colours")
        XCTAssertEqual(fluent.size, ToolbarIcons.size)
        XCTAssertNotNil(ToolbarIcons.image(for: wrap, iconSet: .filledFluent))
        XCTAssertNotNil(fluent.cgImage(forProposedRect: nil, context: nil, hints: nil), "it draws")
    }

    func testAMissingFluentIconFallsBackToTheSymbol() {
        let button = ToolbarButton(nppCommand: "IDM_X", label: "X", action: nil, symbol: "star", fluentStem: "no-such-icon")
        XCTAssertNil(ToolbarIcons.fluentImage(stem: "no-such-icon", filled: false))
        XCTAssertTrue(ToolbarIcons.image(for: button, iconSet: .fluent)?.isTemplate ?? false)
    }

    func testTheFluentIconFollowsDarkMode() throws {
        let image = try XCTUnwrap(ToolbarIcons.fluentImage(stem: "save", filled: false))
        func pixels(_ appearance: NSAppearance.Name) -> Data? {
            var data: Data?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
                NSGraphicsContext.restoreGraphicsState()
                data = rep.tiffRepresentation
            }
            return data
        }
        XCTAssertNotEqual(pixels(.aqua), pixels(.darkAqua), "the light and dark files are drawn")
    }

    // MARK: - Items

    func testItemsCarryLabelActionAndIcon() throws {
        let delegate = MainToolbar(iconSet: .sfSymbols)
        for id in ToolbarLayout.defaultIdentifiers where id != .space {
            let item = try XCTUnwrap(delegate.toolbar(delegate.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
                                     as? CommandToolbarItem)
            XCTAssertEqual(item.label, item.button.label)
            XCTAssertEqual(item.paletteLabel, item.button.label)
            XCTAssertEqual(item.control.action, item.button.action)
            XCTAssertNil(item.control.target, "sent along the responder chain")
            XCTAssertNotNil(item.control.image)
            XCTAssertEqual(item.menuFormRepresentation?.action, item.button.action, "the overflow menu works too")
            XCTAssertTrue(item.control.constraints.contains { $0.firstAttribute == .width && $0.constant == CommandToolbarItem.buttonWidth },
                          "one width for every icon set")
        }
        XCTAssertTrue(delegate.toolbar.allowsUserCustomization)
        XCTAssertTrue(delegate.toolbar.autosavesConfiguration)
        XCTAssertEqual(delegate.toolbarAllowedItemIdentifiers(delegate.toolbar).filter { $0 != .space && $0 != .flexibleSpace },
                       ToolbarLayout.available.joined().map(\.identifier))
    }

    func testChangingTheIconSetUpdatesTheItems() throws {
        let delegate = MainToolbar(iconSet: .sfSymbols)
        let id = ToolbarLayout.defaultIdentifiers[0]
        let item = try XCTUnwrap(delegate.toolbar(delegate.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
                                 as? CommandToolbarItem)
        XCTAssertTrue(item.control.image?.isTemplate ?? false)
        item.setIconSet(.filledFluent)
        XCTAssertFalse(item.control.image?.isTemplate ?? true)
        delegate.setIconSet(.fluent)
        XCTAssertEqual(delegate.iconSet, .fluent)
    }

    // MARK: - Validation

    private final class Target: NSObject, NSMenuItemValidation {
        var enabled = true
        var on = false
        @objc func command(_ sender: Any?) {}
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            item.state = on ? .on : .off
            return enabled
        }
    }

    private final class UITarget: NSObject, NSUserInterfaceValidations {
        @objc func command(_ sender: Any?) {}
        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { false }
    }

    func testAButtonShowsWhatTheMenuItemWould() {
        let target = Target()
        let action = #selector(Target.command(_:))
        XCTAssertEqual(ToolbarValidation.state(for: action, target: target), .init(isEnabled: true, isOn: false))
        target.on = true
        XCTAssertEqual(ToolbarValidation.state(for: action, target: target), .init(isEnabled: true, isOn: true))
        target.enabled = false
        XCTAssertFalse(ToolbarValidation.state(for: action, target: target).isEnabled)
        XCTAssertFalse(ToolbarValidation.state(for: action, target: UITarget()).isEnabled, "Scintilla validates this way")
        XCTAssertEqual(ToolbarValidation.state(for: action, target: nil), .init(isEnabled: false, isOn: false), "nobody handles it")
    }

    func testTheItemAppliesTheState() throws {
        let button = try XCTUnwrap(ToolbarLayout.groups.joined().first { $0.fluentStem == "wrap" })
        let item = CommandToolbarItem(button: button, iconSet: .sfSymbols)
        item.apply(.init(isEnabled: true, isOn: true))
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.control.state, .on)
        item.apply(.init(isEnabled: false, isOn: false))
        XCTAssertFalse(item.control.isEnabled)
        XCTAssertEqual(item.control.state, .off)
    }

    // MARK: - Window

    func testTheWindowHasTheToolbarUnderItsTitle() throws {
        let window = MainWindowController()
        let toolbar = try XCTUnwrap(window.window?.toolbar)
        XCTAssertEqual(toolbar.identifier, MainToolbar.identifier)
        XCTAssertTrue(toolbar === window.mainToolbar.toolbar)
        XCTAssertEqual(window.window?.toolbarStyle, .expanded)
        window.openTabs.forEach { $0.detach() }
    }

    func testTheWindowsCommandsDriveTheButtons() throws {
        let window = MainWindowController()
        window.newDocument(nil)
        let tab = try XCTUnwrap(window.activeTab)
        let save = #selector(MainWindowController.saveDocument(_:))
        XCTAssertFalse(ToolbarValidation.state(for: save, target: window).isEnabled, "Save is grey while nothing changed")
        tab.editor.send(SCI_APPENDTEXT, 1, string: "x")
        XCTAssertTrue(ToolbarValidation.state(for: save, target: window).isEnabled)

        let wrap = #selector(MainWindowController.toggleWordWrap(_:))
        let before = ToolbarValidation.state(for: wrap, target: window).isOn
        window.toggleWordWrap(nil)
        XCTAssertNotEqual(ToolbarValidation.state(for: wrap, target: window).isOn, before, "Word Wrap shows pressed while on")

        let monitoring = #selector(MainWindowController.toggleMonitoring(_:))
        XCTAssertFalse(ToolbarValidation.state(for: monitoring, target: window).isEnabled, "an unsaved document cannot be monitored")
        XCTAssertTrue(window.validateToolbarCommand(#selector(MainWindowController.zoomInText(_:))))
        window.openTabs.forEach { $0.detach() }
    }

    func testThePreferenceChangesTheWindowsIcons() {
        let window = MainWindowController()
        Preferences.update { $0.toolbarIconSet = .filledFluent }
        let expectation = expectation(description: "applied")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(window.mainToolbar.iconSet, .filledFluent)
        window.openTabs.forEach { $0.detach() }
    }

    func testTheViewMenuShowsAndCustomizesTheToolbar() throws {
        let view = try XCTUnwrap(MainMenu.build().items.first { $0.submenu?.title == "View" }?.submenu)
        let actions = view.items.compactMap(\.action)
        XCTAssertTrue(actions.contains(#selector(NSWindow.toggleToolbarShown(_:))))
        XCTAssertTrue(actions.contains(#selector(NSWindow.runToolbarCustomizationPalette(_:))))
    }

    // MARK: - Preferences

    func testTheIconSetPreference() throws {
        XCTAssertEqual(Preferences().toolbarIconSet, .sfSymbols, "SF Symbols by default")
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"showLineNumbers":false}"#.utf8))
        XCTAssertEqual(old.toolbarIconSet, .sfSymbols, "settings saved before MAC-69 get the default")
        var p = Preferences()
        p.toolbarIconSet = .fluent
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)).toolbarIconSet, .fluent)
    }

    func testThePreferencesWindowsToolbarPage() {
        let c = PreferencesController()
        XCTAssertEqual(c.toolbarIconsPopup.itemTitles, ["SF Symbols (macOS)", "Fluent UI", "Filled Fluent UI"])
        XCTAssertEqual(PreferencesController.toolbarIconTitles.count, Preferences.ToolbarIconSet.allCases.count)
        c.toolbarIconsPopup.selectItem(at: 2)
        c.controlChanged(nil)
        XCTAssertEqual(Preferences.current.toolbarIconSet, .filledFluent)
        XCTAssertEqual(c.tabView.tabViewItems.first?.label, "Toolbar")
    }
}
