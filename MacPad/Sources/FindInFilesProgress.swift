import AppKit

/// Notepad++'s "Find In Files progress..." window: the file being searched, the hits so far, a
/// bar, and Cancel. Shown only when there is more than one file to go through.
final class FindInFilesProgress: NSWindowController {
    private let pathLabel = NSTextField(labelWithString: "")
    private let hitsLabel = NSTextField(labelWithString: "Hits: 0")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = title
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        pathLabel.lineBreakMode = .byTruncatingMiddle  // Notepad++'s path ellipsis
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [pathLabel, hitsLabel, bar, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
                pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        stack.setCustomSpacing(12, after: bar)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showDiscovering(_ directory: String) {
        pathLabel.stringValue = "Discovering file candidates... \(directory)"
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    func update(file: String, hits: Int, done: Int, total: Int) {
        pathLabel.stringValue = file
        hitsLabel.stringValue = "Hits: \(SearchResultsFormat.commafy(hits))"
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = total > 0 ? Double(done) / Double(total) : 0
    }

    @objc private func cancelClicked(_ sender: Any?) {
        pathLabel.stringValue = "Cancelling operation, please wait..."
        cancelButton.isEnabled = false
        onCancel?()
    }
}
