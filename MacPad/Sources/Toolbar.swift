import AppKit

/// MAC-69: Notepad++'s toolbar — the buttons of `toolBarIcons[]` in Notepad_plus.cpp, in the same
/// order and groups (a `0` entry there is a separator; here, a new group). Buttons whose command
/// MacPad++ does not have yet keep their place with a nil `action` and are left out of the toolbar.
struct ToolbarButton: Equatable {
    /// Notepad++'s command id (IDM_…), which ties the button to `toolBarIcons[]`.
    let nppCommand: String
    let label: String
    let action: Selector?
    /// The SF Symbol shown with the default icon set.
    let symbol: String
    /// Notepad++'s Fluent icon: icons/<light|dark>/toolbar/<regular|filled>/<stem>_off.ico.
    let fluentStem: String

    var identifier: NSToolbarItem.Identifier { .init("npp.\(fluentStem)") }
}

enum ToolbarLayout {
    private typealias B = ToolbarButton
    private typealias W = MainWindowController
    private typealias A = AppDelegate

    static let groups: [[ToolbarButton]] = [
        [B(nppCommand: "IDM_FILE_NEW", label: "New", action: #selector(A.newDocument(_:)), symbol: "doc.badge.plus", fluentStem: "new"),
         B(nppCommand: "IDM_FILE_OPEN", label: "Open", action: #selector(A.openDocument(_:)), symbol: "folder", fluentStem: "open"),
         B(nppCommand: "IDM_FILE_SAVE", label: "Save", action: #selector(W.saveDocument(_:)), symbol: "square.and.arrow.down", fluentStem: "save"),
         B(nppCommand: "IDM_FILE_SAVEALL", label: "Save All", action: nil, symbol: "square.and.arrow.down.on.square", fluentStem: "saveall"),
         B(nppCommand: "IDM_FILE_CLOSE", label: "Close", action: #selector(W.closeTab(_:)), symbol: "xmark.square", fluentStem: "close"),
         B(nppCommand: "IDM_FILE_CLOSEALL", label: "Close All", action: nil, symbol: "xmark.square.fill", fluentStem: "closeall"),
         B(nppCommand: "IDM_FILE_PRINT", label: "Print", action: nil, symbol: "printer", fluentStem: "print")],
        [B(nppCommand: "IDM_EDIT_CUT", label: "Cut", action: #selector(NSText.cut(_:)), symbol: "scissors", fluentStem: "cut"),
         B(nppCommand: "IDM_EDIT_COPY", label: "Copy", action: #selector(NSText.copy(_:)), symbol: "doc.on.doc", fluentStem: "copy"),
         B(nppCommand: "IDM_EDIT_PASTE", label: "Paste", action: #selector(NSText.paste(_:)), symbol: "doc.on.clipboard", fluentStem: "paste")],
        [B(nppCommand: "IDM_EDIT_UNDO", label: "Undo", action: Selector(("undo:")), symbol: "arrow.uturn.backward", fluentStem: "undo"),
         B(nppCommand: "IDM_EDIT_REDO", label: "Redo", action: Selector(("redo:")), symbol: "arrow.uturn.forward", fluentStem: "redo")],
        [B(nppCommand: "IDM_SEARCH_FIND", label: "Find", action: #selector(A.showFindPanel(_:)), symbol: "magnifyingglass", fluentStem: "find"),
         B(nppCommand: "IDM_SEARCH_REPLACE", label: "Replace", action: #selector(A.showReplacePanel(_:)), symbol: "arrow.2.squarepath", fluentStem: "findrep")],
        [B(nppCommand: "IDM_VIEW_ZOOMIN", label: "Zoom In", action: #selector(W.zoomInText(_:)), symbol: "plus.magnifyingglass", fluentStem: "zoomIn"),
         B(nppCommand: "IDM_VIEW_ZOOMOUT", label: "Zoom Out", action: #selector(W.zoomOutText(_:)), symbol: "minus.magnifyingglass", fluentStem: "zoomOut")],
        [B(nppCommand: "IDM_VIEW_SYNSCROLLV", label: "Synchronize Vertical Scrolling", action: #selector(W.toggleSyncVerticalScrolling(_:)),
           symbol: "arrow.up.and.down", fluentStem: "syncV"),
         B(nppCommand: "IDM_VIEW_SYNSCROLLH", label: "Synchronize Horizontal Scrolling", action: #selector(W.toggleSyncHorizontalScrolling(_:)),
           symbol: "arrow.left.and.right", fluentStem: "syncH")],
        [B(nppCommand: "IDM_VIEW_WRAP", label: "Word Wrap", action: #selector(W.toggleWordWrap(_:)), symbol: "arrow.turn.down.left", fluentStem: "wrap"),
         B(nppCommand: "IDM_VIEW_ALL_CHARACTERS", label: "Show All Characters", action: #selector(W.toggleShowAllCharacters(_:)),
           symbol: "paragraphsign", fluentStem: "allChars"),
         B(nppCommand: "IDM_VIEW_INDENT_GUIDE", label: "Show Indent Guide", action: nil, symbol: "increase.indent", fluentStem: "indentGuide")],
        [B(nppCommand: "IDM_LANG_USER_DLG", label: "User Defined Language", action: nil, symbol: "character.book.closed", fluentStem: "udl"),
         B(nppCommand: "IDM_VIEW_DOC_MAP", label: "Document Map", action: #selector(W.toggleDocumentMap(_:)), symbol: "map", fluentStem: "docMap"),
         B(nppCommand: "IDM_VIEW_DOCLIST", label: "Document List", action: nil, symbol: "list.bullet.rectangle", fluentStem: "docList"),
         B(nppCommand: "IDM_VIEW_FUNC_LIST", label: "Function List", action: #selector(W.toggleFunctionList(_:)), symbol: "list.bullet.indent",
           fluentStem: "funcList"),
         B(nppCommand: "IDM_VIEW_FILEBROWSER", label: "Folder as Workspace", action: #selector(W.toggleWorkspace(_:)), symbol: "sidebar.leading",
           fluentStem: "fileBrowser")],
        [B(nppCommand: "IDM_VIEW_MONITORING", label: "Monitoring (tail -f)", action: #selector(W.toggleMonitoring(_:)), symbol: "eye",
           fluentStem: "monitoring")],
        [B(nppCommand: "IDM_MACRO_STARTRECORDINGMACRO", label: "Start Recording", action: #selector(A.startRecording(_:)), symbol: "record.circle",
           fluentStem: "startrecord"),
         B(nppCommand: "IDM_MACRO_STOPRECORDINGMACRO", label: "Stop Recording", action: #selector(A.stopRecording(_:)), symbol: "stop.circle",
           fluentStem: "stoprecord"),
         B(nppCommand: "IDM_MACRO_PLAYBACKRECORDEDMACRO", label: "Playback", action: #selector(A.playbackMacro(_:)), symbol: "play.circle",
           fluentStem: "playrecord"),
         B(nppCommand: "IDM_MACRO_RUNMULTIMACRODLG", label: "Run a Macro Multiple Times", action: #selector(A.showRunMacroDialog(_:)),
           symbol: "forward.circle", fluentStem: "playrecord_m"),
         B(nppCommand: "IDM_MACRO_SAVECURRENTMACRO", label: "Save Current Recorded Macro", action: #selector(A.saveCurrentMacro(_:)),
           symbol: "tray.and.arrow.down", fluentStem: "saverecord")],
    ]

    /// The groups with only the buttons MacPad++ has a command for; empty groups dropped.
    static var available: [[ToolbarButton]] {
        groups.map { $0.filter { $0.action != nil } }.filter { !$0.isEmpty }
    }

    static func button(_ identifier: NSToolbarItem.Identifier) -> ToolbarButton? {
        groups.joined().first { $0.identifier == identifier }
    }

    /// The default toolbar: Notepad++'s buttons, a space where it has a separator.
    static var defaultIdentifiers: [NSToolbarItem.Identifier] {
        Array(available.map { $0.map(\.identifier) }.joined(separator: [.space]))
    }
}

/// The toolbar's icons: SF Symbols, or Notepad++'s Fluent UI set (regular or filled), drawn in its
/// light or dark version to match the window's appearance.
enum ToolbarIcons {
    static let size = NSSize(width: 18, height: 18)
    private static var cache: [URL: NSImage] = [:]

    static func fluentURL(stem: String, dark: Bool, filled: Bool) -> URL? {
        NppData.url("icons/\(dark ? "dark" : "light")/toolbar/\(filled ? "filled" : "regular")/\(stem)_off.ico")
    }

    static func image(for button: ToolbarButton, iconSet: Preferences.ToolbarIconSet) -> NSImage? {
        if iconSet != .sfSymbols, let fluent = fluentImage(stem: button.fluentStem, filled: iconSet == .filledFluent) {
            return fluent
        }
        return NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.label)
    }

    /// Both versions loaded up front; the drawing handler picks one per appearance, so the icon
    /// follows dark mode without being rebuilt. Nil when the icon files are missing.
    static func fluentImage(stem: String, filled: Bool) -> NSImage? {
        guard let light = load(fluentURL(stem: stem, dark: false, filled: filled)),
              let dark = load(fluentURL(stem: stem, dark: true, filled: filled)) else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        image.accessibilityDescription = stem
        return image
    }

    private static func load(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let image = cache[url] { return image }
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else { return nil }
        cache[url] = image
        return image
    }
}

/// Lets the window add toolbar-only rules on top of its menu validation (Notepad++ greys Save on
/// its toolbar while the document is unchanged; the menu item stays enabled, as on the Mac).
protocol ToolbarCommandValidating: AnyObject {
    func validateToolbarCommand(_ action: Selector) -> Bool
}

/// A toolbar button shows what the menu item for the same command would: enabled or not, and on
/// or off for toggles (Word Wrap, panels, Monitoring…).
enum ToolbarValidation {
    struct State: Equatable {
        var isEnabled: Bool
        var isOn: Bool
    }

    static func state(for action: Selector, target: AnyObject?) -> State {
        guard let target else { return State(isEnabled: false, isOn: false) }
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        var enabled = true
        if let validator = target as? NSMenuItemValidation {
            enabled = validator.validateMenuItem(probe)
        } else if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(probe)
        }
        if enabled, let validator = target as? ToolbarCommandValidating {
            enabled = validator.validateToolbarCommand(action)
        }
        return State(isEnabled: enabled, isOn: probe.state == .on)
    }

    /// The object that would receive `action` from the toolbar: the responder chain of the
    /// toolbar's window, then the application and its delegate.
    static func target(for action: Selector, in window: NSWindow?) -> AnyObject? {
        if let responder = window?.firstResponder ?? window,
           let target = sequence(first: responder, next: { $0.nextResponder }).first(where: { $0.responds(to: action) }) {
            return target
        }
        if let controller = window?.windowController, controller.responds(to: action) { return controller }
        if let delegate = window?.delegate as AnyObject?, delegate.responds(to: action) { return delegate }
        return NSApp.target(forAction: action, to: nil, from: nil) as AnyObject?
    }
}

/// One toolbar button. A bordered push-on/push-off button shows a toggle's state the way
/// Notepad++'s checked toolbar buttons do.
final class CommandToolbarItem: NSToolbarItem {
    static let buttonWidth: CGFloat = 30
    let button: ToolbarButton
    let control = NSButton()

    init(button: ToolbarButton, iconSet: Preferences.ToolbarIconSet) {
        self.button = button
        super.init(itemIdentifier: button.identifier)
        label = button.label
        paletteLabel = button.label
        toolTip = button.label
        control.setButtonType(.pushOnPushOff)
        control.bezelStyle = .texturedRounded
        control.isBordered = true
        control.showsBorderOnlyWhileMouseInside = true
        control.imagePosition = .imageOnly
        control.imageScaling = .scaleProportionallyDown
        control.action = button.action
        control.target = nil  // the responder chain: the active editor, its window, the app
        control.toolTip = button.label
        control.setAccessibilityLabel(button.label)
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        // One width for every button, whichever icon set, so Notepad++'s 26 buttons fit a normal window.
        control.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        view = control
        let menuItem = NSMenuItem(title: button.label, action: button.action, keyEquivalent: "")
        menuFormRepresentation = menuItem  // the overflow menu when the window is narrow
        setIconSet(iconSet)
    }

    func setIconSet(_ iconSet: Preferences.ToolbarIconSet) {
        let image = ToolbarIcons.image(for: button, iconSet: iconSet)
        control.image = image
        menuFormRepresentation?.image = image
    }

    override func validate() {
        guard let action = button.action else { isEnabled = false; return }
        apply(ToolbarValidation.state(for: action, target: ToolbarValidation.target(for: action, in: control.window)))
    }

    func apply(_ state: ToolbarValidation.State) {
        isEnabled = state.isEnabled
        control.isEnabled = state.isEnabled
        control.state = state.isOn ? .on : .off
    }
}

/// The main window's toolbar: Notepad++'s buttons, customizable (View › Customize Toolbar…) and
/// hideable like any Mac toolbar; the layout is saved by AppKit.
final class MainToolbar: NSObject, NSToolbarDelegate {
    static let identifier = "MacPadMainToolbar"
    let toolbar = NSToolbar(identifier: MainToolbar.identifier)
    private(set) var iconSet: Preferences.ToolbarIconSet

    init(iconSet: Preferences.ToolbarIconSet) {
        self.iconSet = iconSet
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
    }

    func setIconSet(_ iconSet: Preferences.ToolbarIconSet) {
        guard iconSet != self.iconSet else { return }
        self.iconSet = iconSet
        toolbar.items.compactMap { $0 as? CommandToolbarItem }.forEach { $0.setIconSet(iconSet) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarLayout.defaultIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarLayout.available.joined().map(\.identifier) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let button = ToolbarLayout.button(identifier), button.action != nil else { return nil }
        return CommandToolbarItem(button: button, iconSet: iconSet)
    }
}
