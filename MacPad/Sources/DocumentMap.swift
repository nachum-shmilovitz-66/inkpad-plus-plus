import AppKit

/// Notepad++'s Document Map (MAC-45): the document in a second, zoomed-out Scintilla view (the
/// same document, so it follows every edit), the editor's visible part marked as a band, and the
/// band dragged / clicked / scrolled to move the editor (DocumentMap::scrollMap, ViewZoneDlg).
final class DocumentMapPanel: NSView {
    let map = ScintillaView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let zone = ZoneView()
    private(set) weak var editor: ScintillaView?
    private var attachedDocument = 0

    /// The band over the map; it also takes the mouse, so the map itself is never edited.
    final class ZoneView: NSView {
        var band = NSRect.zero { didSet { needsDisplay = true } }
        var color = NSColor.orange
        var onDrag: ((CGFloat) -> Void)?
        var onScroll: ((CGFloat) -> Void)?
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard band.height > 0 else { return }
            color.withAlphaComponent(0.25).setFill()
            band.fill()
            color.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: band.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        override func mouseDown(with event: NSEvent) { onDrag?(convert(event.locationInWindow, from: nil).y) }
        override func mouseDragged(with event: NSEvent) { onDrag?(convert(event.locationInWindow, from: nil).y) }
        override func scrollWheel(with event: NSEvent) { onScroll?(event.scrollingDeltaY) }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        for view in [map, zone] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        map.send(SCI_SETZOOM, -10)  // Notepad++'s map zoom
        for margin in 0..<5 { map.send(SCI_SETMARGINWIDTHN, margin, 0) }
        map.send(SCI_SETCARETSTYLE, Int(CARETSTYLE_INVISIBLE))
        map.send(SCI_SETCARETLINEVISIBLE, 0)
        map.send(SCI_SETHSCROLLBAR, 0)
        map.send(SCI_SETVSCROLLBAR, 0)
        zone.onDrag = { [weak self] y in self?.moveEditor(toMapY: y) }
        zone.onScroll = { [weak self] delta in self?.scrollEditor(by: delta) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { detachDocument() }

    // MARK: - Following the editor

    /// Shows `editor`'s document (sharing it), painted like it.
    func attach(to editor: ScintillaView?, language: LanguageInfo?) {
        self.editor = editor
        guard let editor, let language else { detachDocument(); zone.band = .zero; return }
        let document = editor.send(SCI_GETDOCPOINTER)
        if document != attachedDocument {
            map.send(SCI_SETDOCPOINTER, 0, document)
            attachedDocument = document
        }
        EditorStyler.apply(language: language, theme: ThemeManager.shared.current, to: map)
        for margin in 0..<5 { map.send(SCI_SETMARGINWIDTHN, margin, 0) }
        map.send(SCI_SETZOOM, -10)
        map.send(SCI_SETCARETSTYLE, Int(CARETSTYLE_INVISIBLE))
        map.send(SCI_SETCARETLINEVISIBLE, 0)
        zone.color = ThemeManager.shared.current.global("Document map").flatMap { $0.foreground }
            .map(StyleConfiguratorController.color) ?? .orange
        sync()
    }

    private func detachDocument() {
        guard attachedDocument != 0 else { return }
        map.send(SCI_SETDOCPOINTER, 0, 0)  // a fresh empty document: the shared one keeps no extra reference
        attachedDocument = 0
    }

    /// scrollMap: the map scrolls to show the editor's visible text, and the band marks it.
    func sync() {
        guard let editor else { return }
        map.send(SCI_SETWRAPMODE, editor.send(SCI_GETWRAPMODE))
        let size = editor.bounds.size
        let higher = editor.send(SCI_POSITIONFROMPOINT, 0, 0)
        let lower = editor.send(SCI_POSITIONFROMPOINT, Int(size.width), Int(size.height))
        map.send(SCI_GOTOPOS, higher)
        map.send(SCI_GOTOPOS, lower)
        let mapLineHeight = CGFloat(map.send(SCI_TEXTHEIGHT, 0))
        let top = CGFloat(map.send(SCI_POINTYFROMPOSITION, 0, higher))
        let bottom: CGFloat
        if editor.send(SCI_GETWRAPMODE) == Int(SC_WRAP_NONE) {
            // Not wrapped: the editor's height, in map lines.
            let editorLineHeight = CGFloat(max(editor.send(SCI_TEXTHEIGHT, 0), 1))
            bottom = top + mapLineHeight * size.height / editorLineHeight
        } else {
            bottom = CGFloat(map.send(SCI_POINTYFROMPOSITION, 0, lower)) + mapLineHeight
        }
        zone.band = NSRect(x: 0, y: top, width: zone.bounds.width, height: max(bottom - top, 2))
    }

    /// A click or drag puts that map line in the middle of the editor.
    func moveEditor(toMapY y: CGFloat) {
        guard let editor else { return }
        let position = map.send(SCI_POSITIONFROMPOINT, 0, Int(y))
        let line = map.send(SCI_VISIBLEFROMDOCLINE, map.send(SCI_LINEFROMPOSITION, position))
        editor.send(SCI_SETFIRSTVISIBLELINE, max(line - editor.send(SCI_LINESONSCREEN) / 2, 0))
        sync()
    }

    /// The mouse wheel over the map scrolls the editor.
    func scrollEditor(by delta: CGFloat) {
        guard let editor, delta != 0 else { return }
        editor.send(SCI_LINESCROLL, 0, delta > 0 ? -3 : 3)
        sync()
    }
}
