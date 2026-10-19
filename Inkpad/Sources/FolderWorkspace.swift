import AppKit

/// upstream's Folder as Workspace (MAC-46): root folders as a lazy tree (folders first, then
/// files, by name; hidden ones left out), double-click opens a file, and the context menus of a
/// root, a folder and a file. The roots are remembered.
final class FolderWorkspacePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Node {
        let url: URL
        let isDirectory: Bool
        weak var parent: Node?
        private var loaded: [Node]?

        init(url: URL, isDirectory: Bool, parent: Node?) {
            self.url = url
            self.isDirectory = isDirectory
            self.parent = parent
        }

        var isRoot: Bool { parent == nil }
        var name: String { url.lastPathComponent }

        /// The folder's entries, read when first needed: folders first, then files, by name.
        var children: [Node] {
            if let loaded { return loaded }
            let list = Self.list(url).map { Node(url: $0.url, isDirectory: $0.isDirectory, parent: self) }
            loaded = list
            return list
        }

        /// Reads the folder again (a refresh), keeping nothing stale.
        func reload() { loaded = nil }

        static func list(_ folder: URL) -> [(url: URL, isDirectory: Bool)] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey]
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles])) ?? []
            return entries.compactMap { entry -> (URL, Bool)? in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                guard values?.isHidden != true else { return nil }
                let isDirectory = values?.isDirectory == true && values?.isPackage != true
                // Under the root as the user chose it (macOS may answer /private/var for /var).
                return (folder.appendingPathComponent(entry.lastPathComponent, isDirectory: isDirectory), isDirectory)
            }.sorted { a, b in
                if a.1 != b.1 { return a.1 }
                return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
            }
        }
    }

    let outline = NSOutlineView()
    private(set) var roots: [Node] = []
    private let defaults: UserDefaults
    private static let rootsKey = "WorkspaceFolders"

    var onOpenFile: ((URL) -> Void)?
    var onFindInFiles: ((URL) -> Void)?
    /// The current document, for "Locate current file".
    var currentFile: () -> URL? = { nil }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        build()
        for path in defaults.stringArray(forKey: Self.rootsKey) ?? [] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                roots.append(Node(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true, parent: nil))
            }
        }
        outline.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Roots

    /// Adds folders as roots (one already there is not added twice).
    func add(_ folders: [URL]) {
        for folder in folders where !roots.contains(where: { $0.url.standardizedFileURL == folder.standardizedFileURL }) {
            roots.append(Node(url: folder.standardizedFileURL, isDirectory: true, parent: nil))
        }
        save()
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
    }

    func remove(_ root: Node) {
        roots.removeAll { $0 === root }
        save()
        outline.reloadData()
    }

    func removeAll() {
        roots.removeAll()
        save()
        outline.reloadData()
    }

    private func save() { defaults.set(roots.map(\.url.path), forKey: Self.rootsKey) }

    /// Reads every expanded folder again (files added or removed outside).
    func refresh() {
        let expanded = expandedURLs()
        func reload(_ node: Node) {
            guard node.isDirectory else { return }
            node.reload()
        }
        roots.forEach(reload)
        outline.reloadData()
        restoreExpanded(expanded)
    }

    private func expandedURLs() -> Set<URL> {
        Set((0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? Node).flatMap { outline.isItemExpanded($0) ? $0.url : nil }
        })
    }

    private func restoreExpanded(_ urls: Set<URL>) {
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, urls.contains(node.url) { outline.expandItem(node) }
            row += 1
        }
    }

    // MARK: - Toolbar

    @objc func expandAll(_ sender: Any?) { roots.forEach { outline.expandItem($0, expandChildren: true) } }
    @objc func collapseAll(_ sender: Any?) { roots.forEach { outline.collapseItem($0, collapseChildren: true) } }

    /// Locate current file: opens the folders down to the current document and selects it.
    @discardableResult
    @objc func locateCurrentFile(_ sender: Any? = nil) -> Bool {
        guard let file = currentFile()?.standardizedFileURL else { return false }
        for root in roots where file.path.hasPrefix(root.url.path + "/") {
            let parts = file.path.dropFirst(root.url.path.count + 1).split(separator: "/").map(String.init)
            var node = root
            outline.expandItem(node)
            for part in parts {
                guard let next = node.children.first(where: { $0.name == part }) else { return false }
                node = next
                if node.isDirectory { outline.expandItem(node) }
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return false }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            return true
        }
        return false
    }

    // MARK: - Opening and the context menus

    @objc func openSelection(_ sender: Any?) {
        guard let node = clickedOrSelected else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpenFile?(node.url)
        }
    }

    private var clickedOrSelected: Node? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? Node
    }

    /// upstream's menus: a root (Remove, Remove All …), a folder, or a file (Open, Run by system …).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedOrSelected else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        if node.isRoot {
            add("Remove", #selector(removeClicked(_:)))
            add("Remove All", #selector(removeAllClicked(_:)))
            menu.addItem(.separator())
        } else if !node.isDirectory {
            add("Open", #selector(openClicked(_:)))
            add("Open with Default App", #selector(runBySystem(_:)))
            menu.addItem(.separator())
        }
        add("Copy Path", #selector(copyPath(_:)))
        add("Copy File Name", #selector(copyName(_:)))
        if node.isDirectory { add("Find in Files…", #selector(findInFiles(_:))) }
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add("Open in Terminal", #selector(openInTerminal(_:)))
    }

    private func node(_ sender: Any?) -> Node? { (sender as? NSMenuItem)?.representedObject as? Node }

    @objc func removeClicked(_ sender: Any?) { node(sender).map(remove) }
    @objc func removeAllClicked(_ sender: Any?) { removeAll() }
    @objc func openClicked(_ sender: Any?) { node(sender).map { onOpenFile?($0.url) } }
    @objc func runBySystem(_ sender: Any?) { node(sender).map { _ = NSWorkspace.shared.open($0.url) } }
    @objc func copyPath(_ sender: Any?) { node(sender).map { MainWindowController.copyToPasteboard($0.url.path) } }
    @objc func copyName(_ sender: Any?) { node(sender).map { MainWindowController.copyToPasteboard($0.name) } }
    @objc func findInFiles(_ sender: Any?) { node(sender).map { onFindInFiles?($0.url) } }
    @objc func revealInFinder(_ sender: Any?) { node(sender).map { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) } }

    /// upstream's "CMD here": a Terminal window in the folder (a file's folder for a file).
    @objc func openInTerminal(_ sender: Any?) {
        guard let node = node(sender) else { return }
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.isDirectory ? node.children.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isDirectory == true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let image = NSImageView(image: NSWorkspace.shared.icon(forFile: node.url.path))
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = node.url.path
        if node.isRoot { label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize + 1) }
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
        outline.doubleAction = #selector(openSelection(_:))
        outline.rowSizeStyle = .small
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
