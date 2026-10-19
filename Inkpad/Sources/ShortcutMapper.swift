import AppKit

/// The user's changes to menu shortcuts (MAC-43), kept by command and applied over the defaults
/// every time the menus are built. upstream keeps these in shortcuts.xml.
final class ShortcutStore {
    static let shared = ShortcutStore()

    struct Shortcut: Codable, Equatable {
        var key: String
        var modifiers: UInt
        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
        static let none = Shortcut(key: "", modifiers: 0)
    }

    private let defaults: UserDefaults
    private static let key = "ShortcutOverrides"
    private(set) var overrides: [String: Shortcut]
    /// Each command's built-in shortcut, learned when the overrides are applied.
    private(set) var builtIn: [String: Shortcut] = [:]

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
    }

    /// A stable name for a menu command: its action, and its tag or represented value.
    static func identifier(of item: NSMenuItem) -> String? {
        guard let action = item.action else { return nil }
        let detail = (item.representedObject as? String) ?? String(item.tag)
        return NSStringFromSelector(action) + "#" + detail
    }

    /// Puts the user's shortcuts on `menu` (recursively), remembering the built-in ones.
    func apply(to menu: NSMenu) {
        for item in menu.items {
            if let sub = item.submenu { apply(to: sub) }
            guard let id = Self.identifier(of: item) else { continue }
            if builtIn[id] == nil {
                builtIn[id] = Shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.rawValue)
            }
            let shortcut = overrides[id] ?? builtIn[id]!
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.flags
        }
    }

    func set(_ shortcut: Shortcut, for id: String) {
        overrides[id] = shortcut
        save()
    }

    /// Back to the built-in shortcut.
    func reset(_ id: String) {
        overrides[id] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: Self.key) }
        if let menu = NSApp?.mainMenu { apply(to: menu) }
    }
}

/// Settings › Shortcut Mapper… (MAC-43): every menu command and every macro with its shortcut,
/// a filter, and Modify / Clear / Reset / Delete, with upstream's conflict warning.
final class ShortcutMapperController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Page: Int { case mainMenu, macros }

    struct Row: Equatable {
        var name: String
        var category: String
        var id: String?          // main menu command
        var macroIndex: Int?     // macro
        var key: String
        var modifiers: NSEvent.ModifierFlags
        var shortcutText: String { ShortcutRules.describe(key: key, modifiers: modifiers) }
    }

    let pages = NSSegmentedControl(labels: ["Main menu", "Macros"], trackingMode: .selectOne, target: nil, action: nil)
    let filterField = NSSearchField()
    let table = NSTableView()
    let conflictLabel = NSTextField(labelWithString: "")
    let modifyButton = NSButton(title: "Modify", target: nil, action: nil)
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private(set) var rows: [Row] = []
    private(set) var page = Page.mainMenu
    private let store: ShortcutStore
    private let macros: MacroStore
    private let menuProvider: () -> NSMenu?
    /// Asked for the new shortcut (and, for a macro, its name); nil = cancelled.
    var askShortcut: (_ name: String, _ nameEditable: Bool, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                      _ completion: @escaping ((String, String, NSEvent.ModifierFlags)?) -> Void) -> Void

    init(store: ShortcutStore = .shared, macros: MacroStore = .shared, menuProvider: @escaping () -> NSMenu? = { NSApp.mainMenu }) {
        self.store = store
        self.macros = macros
        self.menuProvider = menuProvider
        let dialog = ShortcutDialog()
        askShortcut = { name, editable, key, modifiers, completion in
            dialog.run(in: nil, completion: completion)
            dialog.nameField.stringValue = name
            dialog.nameField.isEditable = editable
            dialog.keyField.stringValue = key
            dialog.commandBox.state = modifiers.contains(.command) ? .on : .off
            dialog.controlBox.state = modifiers.contains(.control) ? .on : .off
            dialog.optionBox.state = modifiers.contains(.option) ? .on : .off
            dialog.shiftBox.state = modifiers.contains(.shift) ? .on : .off
            dialog.validate()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Shortcut Mapper"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ page: Page) {
        select(page)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    func select(_ newPage: Page) {
        page = newPage
        pages.selectedSegment = newPage.rawValue
        deleteButton.isHidden = newPage != .macros
        resetButton.isHidden = newPage != .mainMenu
        reload()
    }

    // MARK: - Rows

    /// The rows of the page, matching the filter in name, shortcut or category.
    func reload() {
        var all: [Row] = []
        switch page {
        case .mainMenu:
            func walk(_ menu: NSMenu, path: String) {
                for item in menu.items {
                    if let sub = item.submenu {
                        if ["Recent Files", "Theme", "Macro", "Services"].contains(sub.title) { continue }  // rebuilt lists
                        walk(sub, path: path.isEmpty ? item.title : "\(path) › \(item.title)")
                        continue
                    }
                    guard !item.isSeparatorItem, let id = ShortcutStore.identifier(of: item) else { continue }
                    all.append(Row(name: item.title, category: path, id: id, macroIndex: nil,
                                   key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))
                }
            }
            if let menu = menuProvider() { walk(menu, path: "") }
        case .macros:
            all = macros.macros.enumerated().map {
                Row(name: $0.element.name, category: "Macro", id: nil, macroIndex: $0.offset,
                    key: $0.element.key, modifiers: NSEvent.ModifierFlags(rawValue: $0.element.modifiers))
            }
        }
        let filter = filterField.stringValue.lowercased()
        rows = filter.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(filter) || $0.category.lowercased().contains(filter) || $0.shortcutText.lowercased().contains(filter)
        }
        table.reloadData()
        updateConflict()
    }

    var selectedRow: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    /// upstream's conflict report for the selected command.
    func updateConflict() {
        guard let row = selectedRow, !row.key.isEmpty else { conflictLabel.stringValue = ""; return }
        let mine = row.id.flatMap { id in findItem(id) }
        let conflict = ShortcutRules.conflict(key: row.key, modifiers: row.modifiers, in: menuProvider(), ignoring: mine)
        conflictLabel.stringValue = conflict.map { "CONFLICT FOUND! \(row.shortcutText) is also \($0)" } ?? "No shortcut conflicts for this item."
        conflictLabel.textColor = conflict == nil ? .secondaryLabelColor : .systemRed
    }

    private func findItem(_ id: String, in menu: NSMenu? = nil) -> NSMenuItem? {
        guard let menu = menu ?? menuProvider() else { return nil }
        for item in menu.items {
            if ShortcutStore.identifier(of: item) == id { return item }
            if let sub = item.submenu, let found = findItem(id, in: sub) { return found }
        }
        return nil
    }

    // MARK: - Commands

    func modify() {
        guard let row = selectedRow else { return }
        askShortcut(row.name, row.macroIndex != nil, row.key, row.modifiers) { [weak self] result in
            guard let self, let (name, key, modifiers) = result else { return }
            self.apply(row, name: name, key: key, modifiers: modifiers)
        }
    }

    func apply(_ row: Row, name: String, key: String, modifiers: NSEvent.ModifierFlags) {
        if let id = row.id {
            store.set(ShortcutStore.Shortcut(key: key, modifiers: modifiers.rawValue), for: id)
            menuProvider().map(store.apply)  // the menu this mapper shows takes it at once
        } else if let index = row.macroIndex {
            var macro = macros.macros[index]
            macro.name = name.isEmpty ? macro.name : name
            macro.key = key
            macro.modifiers = modifiers.rawValue
            macros.replace(at: index, with: macro)
        }
        reload()
    }

    func clear() {
        guard let row = selectedRow else { return }
        apply(row, name: row.name, key: "", modifiers: [])
    }

    func resetToDefault() {
        guard let id = selectedRow?.id else { return }
        store.reset(id)
        menuProvider().map(store.apply)
        reload()
    }

    func deleteMacro() {
        guard let index = selectedRow?.macroIndex else { return }
        macros.remove(at: index)
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text: String
        switch column?.identifier.rawValue {
        case "shortcut": text = r.shortcutText
        case "category": text = r.category
        default: text = r.name
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateConflict() }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func pageChanged(_ sender: NSSegmentedControl) { select(Page(rawValue: sender.selectedSegment) ?? .mainMenu) }
    @objc private func modifyClicked(_ sender: Any?) { modify() }
    @objc private func clearClicked(_ sender: Any?) { clear() }
    @objc private func resetClicked(_ sender: Any?) { resetToDefault() }
    @objc private func deleteClicked(_ sender: Any?) { deleteMacro() }

    private func build() {
        guard let content = window?.contentView else { return }
        pages.target = self
        pages.action = #selector(pageChanged(_:))
        filterField.placeholderString = "Filter"
        filterField.delegate = self
        for (id, title, width) in [("name", "Name", 300.0), ("shortcut", "Shortcut", 120.0), ("category", "Category", 240.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(modifyClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (button, action) in [(modifyButton, #selector(modifyClicked(_:))), (clearButton, #selector(clearClicked(_:))),
                                 (resetButton, #selector(resetClicked(_:))), (deleteButton, #selector(deleteClicked(_:)))] {
            button.target = self
            button.action = action
        }
        conflictLabel.lineBreakMode = .byTruncatingTail
        let buttons = NSStackView(views: [modifyButton, clearButton, resetButton, deleteButton])
        let root = NSStackView(views: [pages, filterField, scroll, conflictLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            filterField.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        select(.mainMenu)
    }
}
