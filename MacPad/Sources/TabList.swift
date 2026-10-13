import Foundation

/// Which documents are open, which one is active, and what happens to the selection when tabs
/// are added, closed or reordered. Kept free of AppKit so the index arithmetic — the part that
/// goes wrong — can be tested directly.
struct TabList<Element> {
    private(set) var items: [Element] = []
    /// nil only while no document is open.
    private(set) var activeIndex: Int?

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var active: Element? {
        guard let activeIndex, items.indices.contains(activeIndex) else { return nil }
        return items[activeIndex]
    }

    subscript(index: Int) -> Element { items[index] }

    /// Appends and activates, as opening a file in Notepad++ does.
    @discardableResult
    mutating func append(_ element: Element) -> Int {
        items.append(element)
        activeIndex = items.count - 1
        return items.count - 1
    }

    mutating func insert(_ element: Element, at index: Int) {
        let index = min(max(index, 0), items.count)
        items.insert(element, at: index)
        activeIndex = index
    }

    /// Closing the active tab activates the one to its right; the rightmost tab falls back to its
    /// left neighbour. Closing an inactive tab keeps the active document active.
    @discardableResult
    mutating func remove(at index: Int) -> Element {
        let removed = items.remove(at: index)
        guard let current = activeIndex else { return removed }
        if items.isEmpty {
            activeIndex = nil
        } else if index < current {
            activeIndex = current - 1
        } else if index == current {
            activeIndex = min(current, items.count - 1)
        }
        return removed
    }

    mutating func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        activeIndex = index
    }

    /// Cmd+Shift+] / [ — wraps around, like Notepad++'s next/previous tab.
    mutating func selectNext() {
        guard let activeIndex, !items.isEmpty else { return }
        self.activeIndex = (activeIndex + 1) % items.count
    }

    mutating func selectPrevious() {
        guard let activeIndex, !items.isEmpty else { return }
        self.activeIndex = (activeIndex - 1 + items.count) % items.count
    }

    /// Dragging a tab. The moved document stays active if it was.
    mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let destination = min(max(destination, 0), items.count - 1)
        guard source != destination else { return }
        let moved = items.remove(at: source)
        items.insert(moved, at: destination)
        guard let current = activeIndex else { return }
        if current == source {
            activeIndex = destination
        } else if source < current, destination >= current {
            activeIndex = current - 1
        } else if source > current, destination <= current {
            activeIndex = current + 1
        }
    }

    func firstIndex(where predicate: (Element) -> Bool) -> Int? {
        items.firstIndex(where: predicate)
    }
}

/// How a document is labelled, in the tab bar and in the window title.
enum TabTitle {
    /// Notepad++ names an unsaved document "new N"; a saved one shows its file name only.
    static func displayName(url: URL?, untitledNumber: Int) -> String {
        url?.lastPathComponent ?? "new \(untitledNumber)"
    }

    /// Unsaved changes are marked on the tab itself, since macOS puts the window's edited dot in
    /// the close button where a single document would show it.
    static func tabLabel(displayName: String, isModified: Bool) -> String {
        isModified ? "• \(displayName)" : displayName
    }
}
