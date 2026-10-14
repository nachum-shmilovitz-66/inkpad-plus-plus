import AppKit

/// Notepad++'s Function List panel (MAC-44): the file as root, classes as nodes, functions as
/// leaves; Sort (A to Z or document order), a search box that flattens matches under the root,
/// double-click / Return to jump, and the leaf of the caret's function selected.
final class FunctionListPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    final class Item {
        let title: String
        let position: Int
        let isLeaf: Bool
        var children: [Item]
        init(title: String, position: Int, isLeaf: Bool, children: [Item] = []) {
            self.title = title
            self.position = position
            self.isLeaf = isLeaf
            self.children = children
        }
    }

    let outline = NSOutlineView()
    let searchField = NSSearchField()
    private(set) var root: Item?
    private(set) var tree: FunctionTree?
    private weak var editor: ScintillaView?
    /// Sort A to Z (Notepad++'s "Sort functions (A to Z) by default" is off).
    var sortAlphabetically = false { didSet { rebuild() } }
    /// Jumps to a function: the editor, the position.
    var onJump: ((ScintillaView, Int) -> Void)?
    /// What the panel last parsed, so a tab or language change re-parses.
    private(set) var parsedEditor: ScintillaView?
    private(set) var parsedLanguage: String?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Parsing

    /// Re-parses the document (Notepad++ does it on activation, language change, save, Reload).
    func reload(editor: ScintillaView?, language: String, fileName: String) {
        self.editor = editor
        parsedEditor = editor
        parsedLanguage = language
        guard let editor, let definition = FunctionParserDefinition.forLanguage(language) else {
            tree = nil
            rebuild()
            return
        }
        // The parser searches the document's target; keep the editor's own target as it was.
        let targetStart = editor.send(SCI_GETTARGETSTART), targetEnd = editor.send(SCI_GETTARGETEND)
        let flags = editor.send(SCI_GETSEARCHFLAGS)
        let entries = FunctionListParser(editor: editor, definition: definition).parse()
        editor.send(SCI_SETTARGETRANGE, targetStart, targetEnd)
        editor.send(SCI_SETSEARCHFLAGS, flags)
        tree = FunctionTree(root: fileName, entries: entries)
        rebuild()
    }

    /// The outline from the tree, the sort mode and the search text.
    private func rebuild() {
        guard var shown = tree else {
            root = nil
            outline.reloadData()
            searchField.textColor = .textColor
            return
        }
        let filter = searchField.stringValue
        if !filter.isEmpty { shown = shown.filtered(filter) }
        shown = shown.sorted(alphabetically: sortAlphabetically)
        let children = shown.items.map { item -> Item in
            switch item {
            case .leaf(let e): return Item(title: e.name, position: e.position, isLeaf: true)
            case .node(let n):
                return Item(title: n.name, position: n.position, isLeaf: false,
                            children: n.leaves.map { Item(title: $0.name, position: $0.position, isLeaf: true) })
            }
        }
        root = Item(title: shown.root, position: -1, isLeaf: false, children: children)
        outline.reloadData()
        outline.expandItem(root, expandChildren: !filter.isEmpty)
        if filter.isEmpty { outline.expandItem(root) }
        // No match turns the search box red, as Notepad++'s does.
        searchField.textColor = !filter.isEmpty && children.isEmpty ? .systemRed : .textColor
    }

    // MARK: - Caret sync

    /// Selects the last function starting at or above the caret's line (Notepad++'s markEntry).
    func markEntry(caretLine: Int) {
        guard let editor, let root else { return }
        var best: (line: Int, item: Item)?
        func walk(_ item: Item) {
            for child in item.children {
                if child.isLeaf, child.position >= 0 {
                    let line = editor.send(SCI_LINEFROMPOSITION, child.position)
                    if line <= caretLine, best == nil || line > best!.line { best = (line, child) }
                }
                walk(child)
            }
        }
        walk(root)
        let target = best?.item ?? root
        let row = outline.row(forItem: target)
        if row >= 0, outline.selectedRow != row {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    var selectedTitle: String? { (outline.item(atRow: outline.selectedRow) as? Item)?.title }

    // MARK: - Actions

    /// Double-click or Return: a function jumps; the root or a class folds / unfolds.
    @objc func activateSelection(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        if item.isLeaf, item.position >= 0, let editor {
            onJump?(editor, item.position)
        } else if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    @objc func toggleSort(_ sender: Any?) { sortAlphabetically.toggle() }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            rebuild()
            return true
        }
        return false
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return root == nil ? 0 : 1 }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return root! }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Item)?.isLeaf ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let symbol = item === root ? "doc.text" : item.isLeaf ? "function" : "cube"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: item.title.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [image, label])
        row.spacing = 4
        return row
    }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateSelection(_:))
        outline.rowSizeStyle = .small
        searchField.placeholderString = "Search"
        searchField.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [searchField, scroll])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8),
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activateSelection(nil) } else { super.keyDown(with: event) }
    }
}
