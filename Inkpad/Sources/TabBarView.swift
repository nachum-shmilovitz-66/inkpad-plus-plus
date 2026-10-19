import AppKit

/// upstream's document tab strip: one tab per open file, the active one raised, a close button
/// on each tab, and horizontal scrolling once the tabs no longer fit.
final class TabBarView: NSView {
    static let height: CGFloat = 26

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The tab's context menu (Close, Move / Clone to Other View).
    var onMenu: ((Int) -> NSMenu?)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TabBarView.height),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Rebuilds the strip. Called whenever a tab is added, closed, renamed or made active —
    /// cheap at the tab counts a text editor sees, and it keeps the view free of stale state.
    /// `isFocusedView`: with two views, the other view's active tab is drawn without the accent
    /// colour, as upstream greys the unfocused view's tab.
    func reload(tabs: [(label: String, toolTip: String?)], activeIndex: Int?, isFocusedView: Bool = true) {
        stack.views.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(index: index, label: tab.label, isActive: index == activeIndex, isFocusedView: isFocusedView)
            item.toolTip = tab.toolTip
            item.onSelect = { [weak self] in self?.onSelect?($0) }
            item.onClose = { [weak self] in self?.onClose?($0) }
            item.onMenu = { [weak self] in self?.onMenu?($0) }
            stack.addView(item, in: .leading)
        }
        if let activeIndex, stack.views.indices.contains(activeIndex) {
            scroll.contentView.scrollToVisible(stack.views[activeIndex].frame)
        }
        needsDisplay = true
    }
}

/// One tab. Clicking anywhere but the close button selects the document.
private final class TabItemView: NSView {
    private let index: Int
    private let isActive: Bool
    private let isFocusedView: Bool
    private let title: NSTextField
    private let close = NSButton()

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMenu: ((Int) -> NSMenu?)?

    init(index: Int, label: String, isActive: Bool, isFocusedView: Bool) {
        self.index = index
        self.isActive = isActive
        self.isFocusedView = isFocusedView
        title = NSTextField(labelWithString: label)
        super.init(frame: .zero)

        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = isActive ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        close.title = ""
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.imageScaling = .scaleProportionallyDown
        close.isBordered = false
        close.bezelStyle = .inline
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        close.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TabBarView.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 3, width: 1, height: bounds.height - 6).fill()
        if isActive {
            (isFocusedView ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(index)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(index) }

    @objc private func closeClicked() {
        onClose?(index)
    }
}
