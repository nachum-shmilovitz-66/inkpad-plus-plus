import AppKit

/// A docked panel as Notepad++ draws them: a title bar with a close button over its content.
final class DockPanel: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let toolbar = NSStackView()
    private let closeButton = NSButton()
    var onClose: (() -> Void)?

    init(title: String, content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(title)")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        toolbar.spacing = 4
        let bar = NSStackView(views: [titleLabel, NSView(), toolbar, closeButton])
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
        for view in [bar, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A small toolbar button (sort, reload …) on the title bar.
    @discardableResult
    func addTool(symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = target
        button.action = action
        toolbar.addArrangedSubview(button)
        return button
    }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}
