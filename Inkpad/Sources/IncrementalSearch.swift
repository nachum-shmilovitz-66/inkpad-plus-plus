import AppKit

/// upstream's incremental search (FindIncrementDlg, MAC-34): literal text, Match case only,
/// always wrapping. Typing re-searches from the current match; Enter / > go on, Shift-Enter / <
/// go back. The status reads "3/12", with upstream's wrap notes, or "Phrase not found".
struct IncrementalSearch {
    let editor: ScintillaView

    enum Status: Equatable {
        case found, endReached, topReached, notFound
    }

    enum Kind { case first, next, previous }

    /// Searches and selects the match (caret at its end). An empty text finds nothing and
    /// changes nothing.
    @discardableResult
    func search(_ text: String, matchCase: Bool, kind: Kind) -> Status {
        guard !text.isEmpty else { return .found }
        var options = SearchOptions(mode: .normal, matchCase: matchCase, wholeWord: false, wrapAround: true)
        options.backward = kind == .previous
        let engine = SearchEngine(editor: editor)
        switch engine.findNext(text, options: options, fromSelectionStart: kind == .first, nextIncremental: kind != .first) {
        case .found(_, let wrapped):
            editor.send(SCI_CHOOSECARETX)
            guard wrapped else { return .found }
            return kind == .previous ? .topReached : .endReached
        case .notFound, .invalidRegex:
            return .notFound
        }
    }

    /// Every match in the document (Count's cache).
    func matches(_ text: String, matchCase: Bool) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        let options = SearchOptions(mode: .normal, matchCase: matchCase, wholeWord: false, wrapAround: true)
        _ = SearchEngine(editor: editor).processAll(.count, text, replacement: "", options: options) {
            ranges.append($0.start..<$0.end)
        }
        return ranges
    }

    /// upstream's setFindStatus text.
    static func statusText(_ status: Status, nth: Int?, total: Int?) -> String {
        if status == .notFound { return "Phrase not found" }
        var base = ""
        if let total, total > 0, let nth {
            base = "\(SearchResultsFormat.commafy(nth))/\(SearchResultsFormat.commafy(total))"
        }
        let note: String
        switch status {
        case .endReached: note = "Reached end of page, continued from top"
        case .topReached: note = "Reached top of page, continued from bottom"
        default: return base
        }
        return base.isEmpty ? note : base + " - " + note
    }

    /// Highlight all: indicator 28 on every occurrence of the selected text (the match just
    /// found), cleared first and left empty when there is nothing to show.
    func highlightAll(enabled: Bool, fieldText: String, matchCase: Bool) {
        let length = editor.send(SCI_GETLENGTH)
        editor.send(SCI_SETINDICATORCURRENT, MarkIndicator.incremental)
        editor.send(SCI_INDICATORCLEARRANGE, 0, length)
        let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        guard enabled, !fieldText.isEmpty, end > start else { return }
        let token = String(decoding: editor.utf8Bytes()[start..<end], as: UTF8.self)
        for range in matches(token, matchCase: matchCase) where !range.isEmpty {
            editor.send(SCI_SETINDICATORCURRENT, MarkIndicator.incremental)
            editor.send(SCI_INDICATORFILLRANGE, range.lowerBound, range.count)
        }
    }
}

/// The incremental search bar, docked at the bottom of the window above the status bar.
final class IncrementalSearchBar: NSView, NSTextFieldDelegate {
    var editorProvider: () -> ScintillaView? = { nil }
    var onClose: (() -> Void)?

    let field = NSTextField()
    let previousButton = NSButton(title: "<", target: nil, action: nil)
    let nextButton = NSButton(title: ">", target: nil, action: nil)
    let matchCaseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let highlightAllBox = NSButton(checkboxWithTitle: "Highlight all", target: nil, action: nil)
    let countBox = NSButton(checkboxWithTitle: "Count", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private(set) var lastStatus: IncrementalSearch.Status = .found
    /// Count's cache: every match of the current text, dropped when the text, the case option or
    /// the document changes.
    private var cachedMatches: [Range<Int>]?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var search: IncrementalSearch? { editorProvider().map(IncrementalSearch.init) }

    /// Search › Incremental Search: the selection (if any) becomes the text and is searched,
    /// then the field takes focus with its text selected.
    func open() {
        if let editor = editorProvider() {
            let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
            if end > start {
                field.stringValue = String(decoding: editor.utf8Bytes()[start..<end], as: UTF8.self)
                textChanged()
            }
        }
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Esc / ✕: clears the highlights and gives the editor back its focus.
    func close() {
        if let editor = editorProvider() {
            editor.send(SCI_SETINDICATORCURRENT, MarkIndicator.incremental)
            editor.send(SCI_INDICATORCLEARRANGE, 0, editor.send(SCI_GETLENGTH))
            window?.makeFirstResponder(editor)
        }
        isHidden = true
        cachedMatches = nil
        onClose?()
    }

    var hasFocus: Bool {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// The document changed (or another tab came forward): the count is stale.
    func resetCount() {
        guard cachedMatches != nil else { return }
        cachedMatches = nil
        if !isHidden { statusLabel.stringValue = "" }
    }

    func textChanged() {
        cachedMatches = nil
        run(.first)
    }

    func next() { run(.next) }
    func previous() { run(.previous) }

    private func run(_ kind: IncrementalSearch.Kind) {
        guard let search else { return }
        let text = field.stringValue
        let matchCase = matchCaseBox.state == .on
        let status = search.search(text, matchCase: matchCase, kind: kind)
        show(status, text: text, editor: search.editor)
        search.highlightAll(enabled: highlightAllBox.state == .on, fieldText: text, matchCase: matchCase)
    }

    private func show(_ status: IncrementalSearch.Status, text: String, editor: ScintillaView) {
        lastStatus = status
        let failed = status == .notFound && !text.isEmpty
        field.backgroundColor = failed ? NSColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1) : .textBackgroundColor
        field.textColor = failed ? .white : .textColor
        guard !text.isEmpty else { statusLabel.stringValue = ""; return }
        var nth: Int?, total: Int?
        if countBox.state == .on && status != .notFound {
            if cachedMatches == nil { cachedMatches = search?.matches(text, matchCase: matchCaseBox.state == .on) }
            let selection = editor.send(SCI_GETSELECTIONSTART)..<editor.send(SCI_GETSELECTIONEND)
            total = cachedMatches?.count
            nth = cachedMatches?.firstIndex(of: selection).map { $0 + 1 }
        }
        statusLabel.stringValue = IncrementalSearch.statusText(status, nth: nth, total: total)
    }

    // MARK: - Controls

    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? previous() : next()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func previousClicked(_ sender: Any?) { previous() }
    @objc private func nextClicked(_ sender: Any?) { next() }
    @objc private func closeClicked(_ sender: Any?) { close() }

    /// Match case re-searches from the current match; when that fails the selection collapses
    /// to where it started, as upstream does.
    @objc private func matchCaseClicked(_ sender: Any?) {
        guard let editor = editorProvider() else { return }
        let oldStart = editor.send(SCI_GETSELECTIONSTART)
        textChanged()
        if lastStatus == .notFound { editor.send(SCI_SETSEL, -1, oldStart) }
    }

    @objc private func highlightAllClicked(_ sender: Any?) {
        search?.highlightAll(enabled: highlightAllBox.state == .on, fieldText: field.stringValue,
                             matchCase: matchCaseBox.state == .on)
    }

    @objc private func countClicked(_ sender: Any?) { cachedMatches = nil }

    private func build() {
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close incremental search")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        field.delegate = self
        field.placeholderString = "Find"
        field.drawsBackground = true
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        previousButton.target = self
        previousButton.action = #selector(previousClicked(_:))
        nextButton.target = self
        nextButton.action = #selector(nextClicked(_:))
        previousButton.toolTip = "Find previous (Shift-Return)"
        nextButton.toolTip = "Find next (Return)"
        matchCaseBox.target = self
        matchCaseBox.action = #selector(matchCaseClicked(_:))
        highlightAllBox.target = self
        highlightAllBox.action = #selector(highlightAllClicked(_:))
        countBox.target = self
        countBox.action = #selector(countClicked(_:))
        countBox.state = .on  // upstream ticks Count by default
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [previousButton, nextButton] { button.bezelStyle = .rounded; button.controlSize = .small }

        let row = NSStackView(views: [closeButton, NSTextField(labelWithString: "Find:"), field, previousButton, nextButton,
                                      matchCaseBox, highlightAllBox, countBox, statusLabel])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
