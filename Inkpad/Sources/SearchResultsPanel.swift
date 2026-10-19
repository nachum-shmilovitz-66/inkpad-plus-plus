import AppKit

/// upstream's "Search results" window (MAC-32), docked under the editor: a read-only Scintilla
/// view styled like upstream's searchResult lexer, newest search on top and older ones folded.
/// Double-click or Return opens a hit, F4 / Shift-F4 step through the latest search, Delete
/// removes a line, file or search, Escape hides the panel.
final class SearchResultsPanel: NSView, ScintillaNotificationProtocol {
    let pane = ScintillaView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    private let titleLabel = NSTextField(labelWithString: "Search results")
    private let closeButton = NSButton()
    private(set) var model = SearchResultsModel()
    private(set) var lines: [SearchResultsLine] = [.end]
    private let defaults: UserDefaults
    private var eventMonitor: Any?

    /// Opens the document of a hit and selects that one of its ranges.
    var onOpen: ((SearchResultHit, Int) -> Void)?
    /// Open Selected Pathname(s).
    var onOpenPath: ((String) -> Void)?
    /// Escape or the close button.
    var onClose: (() -> Void)?

    private static let wrapKey = "SearchResultsWordWrap"
    private static let purgeKey = "SearchResultsPurge"

    /// "Purge for every search": each Find All replaces the earlier results (off by default).
    var purgeForEverySearch: Bool {
        get { defaults.bool(forKey: Self.purgeKey) }
        set { defaults.set(newValue, forKey: Self.purgeKey) }
    }

    /// "Word wrap long lines" (off by default).
    var wrapLongLines: Bool {
        get { defaults.bool(forKey: Self.wrapKey) }
        set {
            defaults.set(newValue, forKey: Self.wrapKey)
            applyWrap()
        }
    }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        buildLayout()
        configurePane()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    // MARK: - Results

    /// A new Find All goes on top; the earlier searches stay below, folded.
    func show(_ block: SearchResultsBlock) {
        model.add(block, purge: purgeForEverySearch)
        reload()
        titleLabel.stringValue = "Search results - (\(SearchResultsFormat.commafy(block.hitCount)) \(block.hitCount == 1 ? "hit" : "hits"))"
        for (index, line) in lines.enumerated() {
            if case .searchHeader(let b) = line, b > 0 { pane.send(SCI_FOLDLINE, index, Int(SC_FOLDACTION_CONTRACT)) }
        }
        pane.send(SCI_GOTOPOS, 0)
    }

    func clearAll() {
        model.clear()
        reload()
        titleLabel.stringValue = "Search results"
    }

    /// Writes the model into the pane and styles it as LexSearchResult does.
    private func reload() {
        let (text, newLines) = model.render()
        lines = newLines
        pane.send(SCI_SETREADONLY, 0)
        pane.setUTF8Bytes(Data(text.utf8))
        pane.send(SCI_SETREADONLY, 1)
        restyle()
    }

    private func restyle() {
        let bytes = Array(pane.utf8Bytes())
        for (index, kind) in lines.enumerated() {
            let start = pane.send(SCI_POSITIONFROMLINE, index)
            let length = pane.send(SCI_LINELENGTH, index)  // with the line ending: headers fill to the edge
            guard length > 0 else { continue }
            pane.send(SCI_STARTSTYLING, start)
            let level: Int
            switch kind {
            case .searchHeader:
                pane.send(SCI_SETSTYLING, length, Self.searchHeaderStyle)
                level = Int(SC_FOLDLEVELBASE) | Int(SC_FOLDLEVELHEADERFLAG)
            case .fileHeader:
                pane.send(SCI_SETSTYLING, length, Self.fileHeaderStyle)
                level = (Int(SC_FOLDLEVELBASE) + 1) | Int(SC_FOLDLEVELHEADERFLAG)
            case .hit:
                styleHit(Array(bytes[start..<start + length]), segments: model.hit(kind)?.segments ?? [])
                level = Int(SC_FOLDLEVELBASE) + 2
            case .end:
                level = Int(SC_FOLDLEVELBASE)
            }
            pane.send(SCI_SETFOLDLEVEL, index, level)
        }
    }

    /// "\tLine 12: text": up to the number default, the number to its colon "line number",
    /// the hits "hit word", the rest default.
    private func styleHit(_ line: [UInt8], segments: [Range<Int>]) {
        var styles = [Int](repeating: Self.defaultStyle, count: line.count)
        if let digit = line.firstIndex(where: { (0x30...0x39).contains($0) }),
           let colon = line[digit...].firstIndex(of: UInt8(ascii: ":")) {
            for i in digit..<colon { styles[i] = Self.lineNumberStyle }
        }
        for segment in segments {
            for i in segment where i < styles.count { styles[i] = Self.hitStyle }
        }
        var i = 0
        while i < styles.count {
            var j = i
            while j < styles.count && styles[j] == styles[i] { j += 1 }
            pane.send(SCI_SETSTYLING, j - i, styles[i])
            i = j
        }
    }

    // MARK: - Navigation

    /// Double-click or Return: a header folds or unfolds; a hit opens its document at the hit
    /// under `position` (or the first one on the line).
    func activate(line index: Int, position: Int? = nil) {
        guard lines.indices.contains(index) else { return }
        switch lines[index] {
        case .searchHeader, .fileHeader:
            pane.send(SCI_TOGGLEFOLD, index)
        case .hit:
            guard let hit = model.hit(lines[index]) else { return }
            let lineStart = pane.send(SCI_POSITIONFROMLINE, index)
            let column = position.map { $0 - lineStart }
            let which = column.flatMap { c in hit.segments.firstIndex { $0.contains(c) || ($0.isEmpty && $0.lowerBound == c) } } ?? 0
            select(segment: which, of: hit, onLine: index)
        case .end:
            break
        }
    }

    /// Next / Previous Search Result (F4 / Shift-F4): hit by hit through the search the pane
    /// caret is in (the newest when it is nowhere), wrapping within that search.
    func step(forward: Bool) {
        let caretLine = pane.send(SCI_LINEFROMPOSITION, pane.send(SCI_GETCURRENTPOS))
        let block = blockIndex(ofLine: caretLine) ?? 0
        var stops: [(line: Int, segment: Int, position: Int)] = []
        for (index, kind) in lines.enumerated() {
            guard case .hit(let b, _, _) = kind, b == block, let hit = model.hit(kind) else { continue }
            let lineStart = pane.send(SCI_POSITIONFROMLINE, index)
            for (s, segment) in hit.segments.enumerated() { stops.append((index, s, lineStart + segment.lowerBound)) }
        }
        guard !stops.isEmpty else { NSSound.beep(); return }
        let current = pane.send(SCI_GETSELECTIONSTART)
        let next = forward ? (stops.first { $0.position > current } ?? stops[0])
                           : (stops.last { $0.position < current } ?? stops[stops.count - 1])
        guard let hit = model.hit(lines[next.line]) else { return }
        select(segment: next.segment, of: hit, onLine: next.line)
    }

    private func select(segment: Int, of hit: SearchResultHit, onLine index: Int) {
        let lineStart = pane.send(SCI_POSITIONFROMLINE, index)
        let piece = hit.segments.indices.contains(segment) ? hit.segments[segment] : 0..<0
        pane.send(SCI_ENSUREVISIBLE, index)
        pane.send(SCI_SETSEL, lineStart + piece.lowerBound, lineStart + piece.upperBound)
        pane.send(SCI_SCROLLRANGE, lineStart + piece.lowerBound, lineStart + piece.upperBound)
        onOpen?(hit, min(segment, hit.ranges.count - 1))
    }

    private func blockIndex(ofLine index: Int) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        switch lines[index] {
        case .searchHeader(let b), .fileHeader(let b, _), .hit(let b, _, _): return b
        case .end: return nil
        }
    }

    // MARK: - Commands (context menu and keys)

    /// The pane lines the selection touches.
    var selectedLines: [SearchResultsLine] {
        let first = pane.send(SCI_LINEFROMPOSITION, pane.send(SCI_GETSELECTIONSTART))
        let last = pane.send(SCI_LINEFROMPOSITION, pane.send(SCI_GETSELECTIONEND))
        return (first...last).compactMap { lines.indices.contains($0) ? lines[$0] : nil }
    }

    /// Delete: the line, file or search under the caret.
    func removeCurrent() {
        let index = pane.send(SCI_LINEFROMPOSITION, pane.send(SCI_GETCURRENTPOS))
        guard lines.indices.contains(index), lines[index] != .end else { return }
        model.remove(lines[index])
        reload()
        pane.send(SCI_GOTOLINE, min(index, max(lines.count - 1, 0)))
    }

    @objc func copySelectedLines(_ sender: Any?) { copy(model.copiedLines(selectedLines)) }
    @objc func copySelectedPathnames(_ sender: Any?) { copy(model.paths(selectedLines).joined(separator: "\r\n")) }
    @objc func openSelectedPathnames(_ sender: Any?) { model.paths(selectedLines).forEach { onOpenPath?($0) } }
    @objc func copySelection(_ sender: Any?) {
        let start = pane.send(SCI_GETSELECTIONSTART), end = pane.send(SCI_GETSELECTIONEND)
        guard end > start else { return }
        copy(String(decoding: pane.utf8Bytes()[start..<end], as: UTF8.self))
    }
    @objc func selectAllResults(_ sender: Any?) { pane.send(SCI_SELECTALL) }
    @objc func clearAllResults(_ sender: Any?) { clearAll() }
    @objc func foldAll(_ sender: Any?) { pane.send(SCI_FOLDALL, Int(SC_FOLDACTION_CONTRACT)) }
    @objc func unfoldAll(_ sender: Any?) { pane.send(SCI_FOLDALL, Int(SC_FOLDACTION_EXPAND)) }
    @objc func toggleWrap(_ sender: Any?) { wrapLongLines.toggle() }
    @objc func togglePurge(_ sender: Any?) { purgeForEverySearch.toggle() }
    @objc private func closeClicked(_ sender: Any?) { onClose?() }

    private func copy(_ text: String) { MainWindowController.copyToPasteboard(text) }

    /// upstream's results context menu (without "Find in these search results…").
    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Search results")
        func add(_ title: String, _ action: Selector, state: Bool? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            if let state { item.state = state ? .on : .off }
            menu.addItem(item)
        }
        let hasSelection = pane.send(SCI_GETSELECTIONEND) > pane.send(SCI_GETSELECTIONSTART)
        add("Fold all", #selector(foldAll(_:)))
        add("Unfold all", #selector(unfoldAll(_:)))
        menu.addItem(.separator())
        add("Copy", #selector(copySelection(_:)), enabled: hasSelection)
        add("Copy Selected Line(s)", #selector(copySelectedLines(_:)))
        add("Copy Selected Pathname(s)", #selector(copySelectedPathnames(_:)))
        add("Select all", #selector(selectAllResults(_:)))
        add("Clear all", #selector(clearAllResults(_:)))
        menu.addItem(.separator())
        add("Open Selected Pathname(s)", #selector(openSelectedPathnames(_:)))
        menu.addItem(.separator())
        add("Word wrap long lines", #selector(toggleWrap(_:)), state: wrapLongLines)
        add("Purge for every search", #selector(togglePurge(_:)), state: purgeForEverySearch)
        return menu
    }

    func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let n = notification.pointee
        if Int32(n.nmhdr.code) == SCN_DOUBLECLICK {
            activate(line: Int(n.line), position: Int(n.position))
        }
    }

    /// Return, Delete, Escape and right-click in the pane (Scintilla would otherwise take them).
    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isHidden, event.window === self.window else { return event }
            if event.type == .rightMouseDown {
                let point = self.pane.convert(event.locationInWindow, from: nil)
                guard self.pane.bounds.contains(point) else { return event }
                NSMenu.popUpContextMenu(self.contextMenu(), with: event, for: self.pane)
                return nil
            }
            guard let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: self.pane) else { return event }
            switch Int(event.keyCode) {
            case 36, 76:  // Return, Enter
                self.activate(line: self.pane.send(SCI_LINEFROMPOSITION, self.pane.send(SCI_GETCURRENTPOS)),
                              position: self.pane.send(SCI_GETCURRENTPOS))
            case 51, 117:  // Delete, Forward Delete
                self.removeCurrent()
            case 53:  // Escape
                self.onClose?()
            default:
                return event
            }
            return nil
        }
    }

    // MARK: - Setup

    static let defaultStyle = 0, searchHeaderStyle = 1, fileHeaderStyle = 2, lineNumberStyle = 3, hitStyle = 4
    static let currentLineStyle = 6

    private func configurePane() {
        pane.delegate = self
        let p = pane
        p.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        p.send(SCI_SETEOLMODE, Int(SC_EOL_CRLF))
        p.send(SCI_SETUNDOCOLLECTION, 0)
        p.send(SCI_SETTABWIDTH, 4)
        p.send(SCI_USEPOPUP, Int(SC_POPUP_NEVER))
        p.send(SCI_SETMARGINWIDTHN, Margin.lineNumber, 0)
        p.send(SCI_SETMARGINWIDTHN, Margin.symbol, 0)
        p.send(SCI_SETMARGINTYPEN, Margin.fold, Int(SC_MARGIN_SYMBOL))
        p.send(SCI_SETMARGINMASKN, Margin.fold, Int(SC_MASK_FOLDERS))
        p.send(SCI_SETMARGINWIDTHN, Margin.fold, 14)
        p.send(SCI_SETMARGINSENSITIVEN, Margin.fold, 1)
        p.send(SCI_SETAUTOMATICFOLD, Int(SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE))
        let markers: [(Int32, Int32)] = [
            (SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS), (SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS),
            (SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE), (SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER),
            (SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED), (SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED),
            (SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER),
        ]
        for (num, symbol) in markers { p.send(SCI_MARKERDEFINE, Int(num), Int(symbol)) }
        applyCurrentTheme()
        applyWrap()
        installEventMonitor()
    }

    /// Repaints with the selected theme (MAC-36), keeping the results and their highlights.
    func applyCurrentTheme() {
        applyTheme(ThemeManager.shared.current)
        restyle()
    }

    /// The default style from the theme's Default Style; the rest from its searchResult lexer.
    private func applyTheme(_ theme: StyleTheme) {
        let p = pane
        if let base = theme.global("Default Style") {
            if let font = base.fontName { p.send(SCI_STYLESETFONT, Int(STYLE_DEFAULT), string: font) }
            if let size = base.fontSize { p.send(SCI_STYLESETSIZE, Int(STYLE_DEFAULT), EditorStyler.macFontSize(size)) }
            if let fg = base.foreground { p.send(SCI_STYLESETFORE, Int(STYLE_DEFAULT), fg) }
            if let bg = base.background { p.send(SCI_STYLESETBACK, Int(STYLE_DEFAULT), bg) }
        }
        p.send(SCI_STYLECLEARALL)
        let styles = theme.lexerStyles["searchResult"] ?? []
        for entry in styles {
            if entry.styleID == Self.currentLineStyle {
                if let bg = entry.background { p.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_CARET_LINE_BACK), bg | 0xFF00_0000) }
                continue
            }
            if let fg = entry.foreground { p.send(SCI_STYLESETFORE, entry.styleID, fg) }
            if let bg = entry.background { p.send(SCI_STYLESETBACK, entry.styleID, bg) }
            p.send(SCI_STYLESETBOLD, entry.styleID, entry.isBold ? 1 : 0)
        }
        p.send(SCI_STYLESETEOLFILLED, Self.searchHeaderStyle, 1)
        p.send(SCI_STYLESETEOLFILLED, Self.fileHeaderStyle, 1)
        p.send(SCI_SETCARETLINEVISIBLE, 1)
        p.send(SCI_SETCARETLINEVISIBLEALWAYS, 1)
    }

    private func applyWrap() {
        pane.send(SCI_SETWRAPMODE, Int(wrapLongLines ? SC_WRAP_WORD : SC_WRAP_NONE))
        pane.send(SCI_SETWRAPINDENTMODE, Int(SC_WRAPINDENT_INDENT))
        pane.send(SCI_SETWRAPVISUALFLAGS, Int(SC_WRAPVISUALFLAG_END))
    }

    private func buildLayout() {
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search results")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = "Close"

        let bar = NSStackView(views: [titleLabel, NSView(), closeButton])
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        for view in [bar, pane] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    var title: String { titleLabel.stringValue }
}
