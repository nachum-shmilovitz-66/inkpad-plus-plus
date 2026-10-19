import AppKit

/// One of upstream's two views (MAC-47): a tab bar over its own documents. The window shows
/// the main view, and the other view beside it while that one has documents.
final class EditorPane {
    var tabs = TabList<EditorTab>()
    let tabBar = TabBarView()
    /// The documents' editors, stacked; only the active one is visible.
    let container = NSView()
    /// The tab bar above the editors.
    let view = NSView()

    init() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Puts an editor in this view's stack (taking it from the other view if it was there).
    func host(_ editor: ScintillaView) {
        editor.removeFromSuperview()
        editor.isHidden = true
        container.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: container.topAnchor),
            editor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func contains(_ tab: EditorTab) -> Bool { tabs.items.contains { $0 === tab } }
    func index(of tab: EditorTab) -> Int? { tabs.firstIndex { $0 === tab } }
}

/// Synchronize Vertical / Horizontal Scrolling: the offset between the two views is taken when
/// the option is turned on, and kept as the focused view scrolls (upstream's _syncInfo).
struct ScrollSync: Equatable {
    var vertical = false
    var horizontal = false
    /// Other view's first visible line minus the main view's, when vertical sync was turned on.
    var lineOffset = 0
    /// The same for the horizontal scroll position, in pixels.
    var xOffset = 0

    var isOn: Bool { vertical || horizontal }

    /// Where the other view goes when view `from` (0 = main) is at `line` / `x`.
    func target(fromView from: Int, line: Int, x: Int) -> (line: Int, x: Int) {
        let sign = from == 0 ? 1 : -1
        return (max(line + sign * lineOffset, 0), max(x + sign * xOffset, 0))
    }
}
