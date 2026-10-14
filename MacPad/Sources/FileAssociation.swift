import AppKit
import UniformTypeIdentifiers

/// Where each file type's default app is kept: LaunchServices, or a fake in tests.
protocol DefaultAppStore {
    /// The bundle identifier of the app that opens files with this extension by default.
    func defaultApp(forExtension ext: String) -> String?
    /// Makes the app at `appURL` the default for the extension (macOS may ask the user first).
    func setDefaultApp(_ appURL: URL, forExtension ext: String, completion: @escaping (Error?) -> Void)
    func appURL(bundleIdentifier: String) -> URL?
}

struct LaunchServicesDefaults: DefaultAppStore {
    func defaultApp(forExtension ext: String) -> String? {
        guard let type = UTType(filenameExtension: ext),
              let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    func setDefaultApp(_ appURL: URL, forExtension ext: String, completion: @escaping (Error?) -> Void) {
        guard let type = UTType(filenameExtension: ext) else {
            completion(FileAssociation.Failure.unknownType(ext))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func appURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

/// Notepad++'s File Association (MISC/RegExt, MAC-51): extensions grouped in Notepad++'s
/// categories, registered to MacPad++ as their default app. What counts as registered is what
/// LaunchServices reports, so a change made in Finder's Get Info shows here too. Unregistering
/// hands the extension back to the app that had it before, or to TextEdit.
final class FileAssociation {
    /// Notepad++'s defExtArray, in its order; "customize" takes any extension typed in.
    static let categories: [(name: String, extensions: [String])] = [
        ("Notepad", [".txt", ".log"]),
        ("ms ini/inf", [".ini", ".inf"]),
        ("c, c++, objc", [".h", ".hh", ".hpp", ".hxx", ".c", ".cpp", ".cxx", ".cc", ".m", ".mm",
                          ".vcxproj", ".vcproj", ".props", ".vsprops", ".manifest"]),
        ("java, c#, pascal", [".java", ".cs", ".pas", ".pp", ".inc"]),
        ("web script", [".html", ".htm", ".shtml", ".shtm", ".hta", ".asp", ".aspx", ".css", ".js", ".json",
                        ".mjs", ".jsm", ".jsp", ".php", ".php3", ".php4", ".php5", ".phps", ".phpt", ".phtml",
                        ".xml", ".xhtml", ".xht", ".xul", ".kml", ".xaml", ".xsml"]),
        ("public script", [".sh", ".bsh", ".bash", ".bat", ".cmd", ".nsi", ".nsh", ".lua", ".pl", ".pm", ".py"]),
        ("property script", [".rc", ".as", ".mx", ".vb", ".vbs"]),
        ("fortran, TeX, SQL", [".f", ".for", ".f90", ".f95", ".f2k", ".tex", ".sql"]),
        ("misc", [".nfo", ".mak"]),
        ("customize", []),
    ]
    static let customize = "customize"
    /// Where an unregistered extension goes when the app that had it is gone.
    static let fallbackApp = "com.apple.TextEdit"

    enum Failure: LocalizedError, Equatable {
        case invalidExtension(String)
        case unknownType(String)
        case noAppToRestore(String)

        var errorDescription: String? {
            switch self {
            case .invalidExtension(let ext): "\"\(ext)\" is not a file extension."
            case .unknownType(let ext): "macOS has no file type for \"\(ext)\"."
            case .noAppToRestore(let ext): "No app was found to open \"\(ext)\" files instead of MacPad++."
            }
        }
    }

    private let store: DefaultAppStore
    private let defaults: UserDefaults
    let appIdentifier: String
    let appURL: URL
    private static let previousKey = "FileAssociationPrevious"
    private static let customKey = "FileAssociationCustom"

    init(store: DefaultAppStore = LaunchServicesDefaults(), defaults: UserDefaults = AppEnvironment.defaults,
         appIdentifier: String = Bundle.main.bundleIdentifier ?? "app.macpad.MacPad", appURL: URL = Bundle.main.bundleURL) {
        self.store = store
        self.defaults = defaults
        self.appIdentifier = appIdentifier
        self.appURL = appURL
    }

    /// ".TXT", "txt", " .txt " → ".txt"; nil for anything that is not one extension.
    static func normalize(_ input: String) -> String? {
        var ext = input.trimmingCharacters(in: .whitespaces).lowercased()
        if !ext.hasPrefix(".") { ext = "." + ext }
        let body = ext.dropFirst()
        guard !body.isEmpty, body.count <= 32,
              body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }) else { return nil }
        return ext
    }

    /// Extensions typed into "customize" and registered: remembered, since no category lists them.
    var customExtensions: [String] { defaults.stringArray(forKey: Self.customKey) ?? [] }
    /// The app each registered extension had before, to give it back.
    var previousApps: [String: String] { defaults.dictionary(forKey: Self.previousKey) as? [String: String] ?? [:] }

    func isRegistered(_ ext: String) -> Bool { store.defaultApp(forExtension: String(ext.dropFirst())) == appIdentifier }

    /// Notepad++'s right-hand list: every known extension that MacPad++ opens by default.
    var registered: [String] {
        let known = Self.categories.flatMap(\.extensions) + customExtensions
        var seen = Set<String>()
        return known.filter { seen.insert($0).inserted && isRegistered($0) }.sorted()
    }

    /// Notepad++'s middle list: the category's extensions not registered yet.
    func available(in category: String) -> [String] {
        (Self.categories.first { $0.name == category }?.extensions ?? []).filter { !isRegistered($0) }
    }

    func register(_ input: String, completion: @escaping (Error?) -> Void) {
        guard let ext = Self.normalize(input) else { completion(Failure.invalidExtension(input)); return }
        let bare = String(ext.dropFirst())
        let current = store.defaultApp(forExtension: bare)
        store.setDefaultApp(appURL, forExtension: bare) { [self] error in
            if error == nil {
                if let current, current != appIdentifier {
                    var previous = previousApps
                    previous[ext] = current
                    defaults.set(previous, forKey: Self.previousKey)
                }
                if !Self.categories.contains(where: { $0.extensions.contains(ext) }) && !customExtensions.contains(ext) {
                    defaults.set(customExtensions + [ext], forKey: Self.customKey)
                }
            }
            completion(error)
        }
    }

    func unregister(_ input: String, completion: @escaping (Error?) -> Void) {
        guard let ext = Self.normalize(input) else { completion(Failure.invalidExtension(input)); return }
        let target = [previousApps[ext], Self.fallbackApp].compactMap { $0 }.lazy
            .compactMap { self.store.appURL(bundleIdentifier: $0) }.first
        guard let target else { completion(Failure.noAppToRestore(ext)); return }
        store.setDefaultApp(target, forExtension: String(ext.dropFirst())) { [self] error in
            if error == nil {
                var previous = previousApps
                previous[ext] = nil
                defaults.set(previous, forKey: Self.previousKey)
            }
            completion(error)
        }
    }
}

/// Settings › File Association: categories | supported extensions → ← registered extensions,
/// as Notepad++'s dialog lays them out.
final class FileAssociationPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let model: FileAssociation
    let categoryTable = NSTableView()
    let availableTable = NSTableView()
    let registeredTable = NSTableView()
    let registerButton = NSButton(title: "→", target: nil, action: nil)
    let unregisterButton = NSButton(title: "←", target: nil, action: nil)
    let customField = NSTextField()
    private(set) var available: [String] = []
    private(set) var registered: [String] = []
    /// Errors go here (an alert in the app; tests read them).
    var onError: ((Error) -> Void)?

    init(model: FileAssociation = FileAssociation()) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        build()
        categoryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedCategory: String {
        let row = categoryTable.selectedRow
        return FileAssociation.categories.indices.contains(row) ? FileAssociation.categories[row].name : FileAssociation.categories[0].name
    }

    var isCustomize: Bool { selectedCategory == FileAssociation.customize }

    /// Reads LaunchServices again (Finder's Get Info may have changed something meanwhile).
    func reload() {
        available = model.available(in: selectedCategory)
        registered = model.registered
        availableTable.reloadData()
        registeredTable.reloadData()
        customField.isHidden = !isCustomize
        availableTable.enclosingScrollView?.isHidden = isCustomize
        updateButtons()
    }

    private func updateButtons() {
        registerButton.isEnabled = isCustomize ? FileAssociation.normalize(customField.stringValue) != nil : availableTable.selectedRow >= 0
        unregisterButton.isEnabled = registeredTable.selectedRow >= 0
    }

    @objc func registerClicked(_ sender: Any?) {
        let ext = isCustomize ? customField.stringValue : (available.indices.contains(availableTable.selectedRow) ? available[availableTable.selectedRow] : "")
        guard !ext.isEmpty else { return }
        model.register(ext) { [weak self] error in
            if let error { self?.onError?(error) } else { self?.customField.stringValue = "" }
            self?.reload()
        }
    }

    @objc func unregisterClicked(_ sender: Any?) {
        guard registered.indices.contains(registeredTable.selectedRow) else { return }
        model.unregister(registered[registeredTable.selectedRow]) { [weak self] error in
            if let error { self?.onError?(error) }
            self?.reload()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { reload() }
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case categoryTable: FileAssociation.categories.count
        case availableTable: available.count
        default: registered.count
        }
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch tableView {
        case categoryTable: FileAssociation.categories[row].name
        case availableTable: available[row]
        default: registered[row]
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === categoryTable { reload() } else { updateButtons() }
    }

    func controlTextDidChange(_ obj: Notification) { updateButtons() }

    private static let listWidth: CGFloat = 150
    /// Three lists, the arrow buttons and the gaps between them.
    private static let width: CGFloat = 3 * listWidth + 44 + 3 * 12

    private func build() {
        func list(_ table: NSTableView, _ title: String) -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            table.addTableColumn(column)
            table.dataSource = self
            table.delegate = self
            table.rowSizeStyle = .small
            table.usesAlternatingRowBackgroundColors = true
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
            return scroll
        }
        registerButton.target = self
        registerButton.action = #selector(registerClicked(_:))
        unregisterButton.target = self
        unregisterButton.action = #selector(unregisterClicked(_:))
        registerButton.toolTip = "Make MacPad++ the default app for this extension"
        unregisterButton.toolTip = "Give this extension back to the app that had it before"
        availableTable.doubleAction = #selector(registerClicked(_:))
        availableTable.target = self
        registeredTable.doubleAction = #selector(unregisterClicked(_:))
        registeredTable.target = self
        customField.placeholderString = ".ext"
        customField.delegate = self
        customField.target = self
        customField.action = #selector(registerClicked(_:))

        let middle = NSStackView(views: [list(availableTable, "Supported exts"), customField])
        middle.orientation = .vertical
        middle.alignment = .leading
        middle.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
        customField.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
        let buttons = NSStackView(views: [registerButton, unregisterButton])
        buttons.orientation = .vertical
        let lists = NSStackView(views: [list(categoryTable, "Category"), middle, buttons, list(registeredTable, "Registered exts")])
        lists.alignment = .top
        lists.spacing = 12
        let note = NSTextField(wrappingLabelWithString:
            "Registering makes MacPad++ the app that opens these files from Finder. macOS may ask you to confirm. "
            + "Unregistering gives the extension back to the app that had it before.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = Self.width
        let stack = NSStackView(views: [lists, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }
}

extension FileAssociationPane: NSTextFieldDelegate {}
