import AppKit

/// Notepad++'s status bar: language · length/lines · Ln/Col/Pos · EOL · encoding · INS/OVR.
final class StatusBar: NSView {
    private let language = StatusBar.label(alignment: .left)
    private let size = StatusBar.label()
    private let caret = StatusBar.label()
    private let lineEnding = StatusBar.clickableLabel(tip: "Click to convert the line endings")
    private let encoding = StatusBar.clickableLabel(tip: "Click to convert the encoding")
    private let mode = StatusBar.label()

    /// Clicked the line-ending / encoding label; the argument is the label, to anchor a menu on.
    var onLineEndingClick: ((NSView) -> Void)? {
        get { lineEnding.onClick }
        set { lineEnding.onClick = newValue }
    }
    var onEncodingClick: ((NSView) -> Void)? {
        get { encoding.onClick }
        set { encoding.onClick = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [language, size, caret, lineEnding, encoding, mode])
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        language.setContentHuggingPriority(.defaultLow, for: .horizontal)
        language.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(language: String, length: Int, lines: Int, line: Int, column: Int, position: Int,
                lineEnding: String, encoding: String, overtype: Bool) {
        self.language.stringValue = language
        size.stringValue = "length : \(length.formatted())    lines : \(lines.formatted())"
        caret.stringValue = "Ln : \(line.formatted())    Col : \(column.formatted())    Pos : \(position.formatted())"
        self.lineEnding.stringValue = lineEnding
        self.encoding.stringValue = encoding
        mode.stringValue = overtype ? "OVR" : "INS"
    }

    private static func label(alignment: NSTextAlignment = .right) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func clickableLabel(tip: String) -> ClickableLabel {
        let field = ClickableLabel(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = tip
        return field
    }
}

/// A status-bar label that acts on a click, as Notepad++'s EOL and encoding panes do.
final class ClickableLabel: NSTextField {
    var onClick: ((NSView) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick(self)
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // Accessibility: present as a button and honour "press", so VoiceOver and other assistive
    // tools can open the picker as well as the mouse can.
    override func accessibilityRole() -> NSAccessibility.Role? {
        onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick(self)
        return true
    }
}
