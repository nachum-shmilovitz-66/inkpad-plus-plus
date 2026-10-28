import AppKit

/// upstream's Preferences that make sense on a Mac (MAC-38, with MAC-12's font scaling and new
/// document line ending). Stored in the app's defaults; a change is announced so open editors
/// update at once, as upstream applies its settings live.
struct Preferences: Codable, Equatable {
    // MARK: New Document
    enum NewDocEncoding: String, Codable, CaseIterable {
        case ansi, utf8, utf8BOM, utf16BE, utf16LE
        var encoding: TextEncoding {
            switch self {
            case .ansi: return .ansi
            case .utf8: return .utf8
            case .utf8BOM: return .utf8BOM
            case .utf16BE: return .utf16BE
            case .utf16LE: return .utf16LE
            }
        }
    }
    /// upstream defaults to Windows (CR LF); on a Mac new documents use Unix (LF).
    var newDocLineEnding = LineEnding.lf
    var newDocEncoding = NewDocEncoding.utf8
    var newDocLanguage = "normal"

    // MARK: Editing
    enum CurrentLineIndicator: Int, Codable, CaseIterable { case none, highlight, frame }
    enum LineWrap: String, Codable, CaseIterable { case `default`, aligned, indent }
    var currentLineIndicator = CurrentLineIndicator.highlight
    var currentLineFrameWidth = 1
    /// 0–3 line widths, 4 Block, 5 Block After.
    var caretWidth = 1
    /// Milliseconds; 0 = no blink.
    var caretBlinkRate = 600
    var lineWrap = LineWrap.aligned
    var virtualSpace = false
    var scrollBeyondLastLine = true
    var dragAndDrop = true
    var multiEditing = true
    /// EOL shown as rounded boxes (upstream's default) or plain text.
    var eolRounded = true
    /// MAC-80: extra pixels between lines (split above and below), for a calmer, BBEdit-like page.
    var lineSpacing = 2
    static let lineSpacingChoices = [0, 1, 2, 3, 4, 6]

    // MARK: Margins / Border / Edge
    enum FoldMarkStyle: String, Codable, CaseIterable { case simple, arrow, circle, box, none }
    /// MAC-80: triangles, as on the Mac (upstream's default is the box tree).
    var foldMarkStyle = FoldMarkStyle.arrow
    var showLineNumbers = true
    var lineNumberDynamicWidth = true
    var showBookmarkMargin = true
    var edgeColumns: [Int] = []
    var edgeBackgroundMode = false
    var paddingLeft = 0
    var paddingRight = 0

    // MARK: Indentation
    struct TabSetting: Codable, Equatable {
        var size = 4
        var useSpaces = false
        var backspaceUnindent = false
    }
    var defaultTabs = TabSetting()
    /// Per-language overrides, by langs.model.xml name; absent = langs.model.xml's, else the default.
    var languageTabs: [String: TabSetting] = [:]
    var sqlBackslashEscapes = true

    // MARK: Searching
    var inSelectionThreshold = 1024
    var fillFindWithSelection = true
    var fillFindMaxCharacters = 1024
    var selectWordUnderCaret = true
    var findDialogStaysOpen = false
    var confirmReplaceInAllOpened = true
    var replaceStopsWithoutFindingNext = false

    // MARK: Recent files, fonts
    var maxRecentFiles = 10
    /// MAC-12: upstream sizes are Windows points; scaled by 4/3 they look the size they do there.
    var scaleWindowsFontSizes = true
    /// MAC-81: the window title shows the document's full path (~ for the home folder).
    var showFullPathInTitle = true

    // MARK: Toolbar (MAC-69)
    /// upstream's Preferences › Toolbar icon choice: SF Symbols (the Mac default), or its Fluent UI
    /// icons, regular or filled.
    enum ToolbarIconSet: String, Codable, CaseIterable { case sfSymbols, fluent, filledFluent }
    var toolbarIconSet = ToolbarIconSet.sfSymbols

    // MARK: Updates (MAC-75)
    /// upstream's Misc. › auto-updater: look for a new release at launch, at most once a day.
    var checkForUpdatesAutomatically = true

    init() {}

    /// Settings saved by an older version keep their values; newer ones take their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        newDocLineEnding = v(.newDocLineEnding, d.newDocLineEnding)
        newDocEncoding = v(.newDocEncoding, d.newDocEncoding)
        newDocLanguage = v(.newDocLanguage, d.newDocLanguage)
        currentLineIndicator = v(.currentLineIndicator, d.currentLineIndicator)
        currentLineFrameWidth = v(.currentLineFrameWidth, d.currentLineFrameWidth)
        caretWidth = v(.caretWidth, d.caretWidth)
        caretBlinkRate = v(.caretBlinkRate, d.caretBlinkRate)
        lineWrap = v(.lineWrap, d.lineWrap)
        virtualSpace = v(.virtualSpace, d.virtualSpace)
        scrollBeyondLastLine = v(.scrollBeyondLastLine, d.scrollBeyondLastLine)
        dragAndDrop = v(.dragAndDrop, d.dragAndDrop)
        multiEditing = v(.multiEditing, d.multiEditing)
        eolRounded = v(.eolRounded, d.eolRounded)
        lineSpacing = v(.lineSpacing, d.lineSpacing)
        foldMarkStyle = v(.foldMarkStyle, d.foldMarkStyle)
        showLineNumbers = v(.showLineNumbers, d.showLineNumbers)
        lineNumberDynamicWidth = v(.lineNumberDynamicWidth, d.lineNumberDynamicWidth)
        showBookmarkMargin = v(.showBookmarkMargin, d.showBookmarkMargin)
        edgeColumns = v(.edgeColumns, d.edgeColumns)
        edgeBackgroundMode = v(.edgeBackgroundMode, d.edgeBackgroundMode)
        paddingLeft = v(.paddingLeft, d.paddingLeft)
        paddingRight = v(.paddingRight, d.paddingRight)
        defaultTabs = v(.defaultTabs, d.defaultTabs)
        languageTabs = v(.languageTabs, d.languageTabs)
        sqlBackslashEscapes = v(.sqlBackslashEscapes, d.sqlBackslashEscapes)
        inSelectionThreshold = v(.inSelectionThreshold, d.inSelectionThreshold)
        fillFindWithSelection = v(.fillFindWithSelection, d.fillFindWithSelection)
        fillFindMaxCharacters = v(.fillFindMaxCharacters, d.fillFindMaxCharacters)
        selectWordUnderCaret = v(.selectWordUnderCaret, d.selectWordUnderCaret)
        findDialogStaysOpen = v(.findDialogStaysOpen, d.findDialogStaysOpen)
        confirmReplaceInAllOpened = v(.confirmReplaceInAllOpened, d.confirmReplaceInAllOpened)
        replaceStopsWithoutFindingNext = v(.replaceStopsWithoutFindingNext, d.replaceStopsWithoutFindingNext)
        maxRecentFiles = v(.maxRecentFiles, d.maxRecentFiles)
        scaleWindowsFontSizes = v(.scaleWindowsFontSizes, d.scaleWindowsFontSizes)
        toolbarIconSet = v(.toolbarIconSet, d.toolbarIconSet)
        showFullPathInTitle = v(.showFullPathInTitle, d.showFullPathInTitle)
        checkForUpdatesAutomatically = v(.checkForUpdatesAutomatically, d.checkForUpdatesAutomatically)
    }

    /// The tab setting a language gets: the user's override, else langs.model.xml's, else the default.
    func tabs(for language: String) -> TabSetting {
        if let own = languageTabs[language] { return own }
        let def = LanguageCatalog.shared.languages[language]
        if let encoded = def?.tabSettings, encoded & 0x7F != 0 {
            return TabSetting(size: encoded & 0x7F, useSpaces: encoded & 0x80 != 0, backspaceUnindent: def?.backspaceUnindent ?? false)
        }
        return defaultTabs
    }

    // MARK: - Storage

    static let didChange = Notification.Name("InkpadPreferencesDidChange")
    private static let key = "Preferences"

    static func load(_ defaults: UserDefaults = AppEnvironment.defaults) -> Preferences {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    func save(_ defaults: UserDefaults = AppEnvironment.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The live settings (read often, so cached; refreshed on every save).
    static var current: Preferences {
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }
    private static var cached: Preferences?

    /// Changes the live settings and announces them.
    static func update(_ change: (inout Preferences) -> Void) {
        var prefs = current
        change(&prefs)
        cached = prefs
        prefs.save()
    }

    /// For tests: forget the cache (the defaults are read again).
    static func resetCache() { cached = nil }
}

extension LineEnding: Codable {}
