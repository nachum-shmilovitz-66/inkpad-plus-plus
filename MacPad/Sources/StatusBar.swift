import AppKit

/// Notepad++'s status bar: language · length/lines · Ln/Col/Pos · EOL · encoding · INS/OVR.
final class StatusBar: NSView {
    private let language = StatusBar.label(alignment: .left)
    private let size = StatusBar.label()
    private let caret = StatusBar.label()
    private let lineEnding = StatusBar.label()
    private let encoding = StatusBar.label()
    private let mode = StatusBar.label()

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
}
