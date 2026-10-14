import XCTest
@testable import MacPad

/// MAC-46: Folder as Workspace.
final class FolderWorkspaceTests: XCTestCase {
    private var root: URL!
    private let suite = "app.macpad.MacPad.tests.workspace"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPadWS-\(UUID().uuidString)", isDirectory: true)
        for path in ["b.txt", "A.md", "src/main.c", "src/util/x.h", ".git/config", "zeta/readme"] {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: url)
        }
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFoldersFirstThenFilesByNameWithoutHiddenOnes() {
        XCTAssertEqual(FolderWorkspacePanel.Node.list(root).map(\.url.lastPathComponent), ["src", "zeta", "A.md", "b.txt"])
    }

    func testRootsAreAddedOnceRemovedAndRemembered() {
        let panel = FolderWorkspacePanel(defaults: defaults)
        panel.add([root, root])
        XCTAssertEqual(panel.roots.count, 1)
        XCTAssertEqual(FolderWorkspacePanel(defaults: defaults).roots.map(\.url.path), [root.standardizedFileURL.path], "kept across launches")
        panel.remove(panel.roots[0])
        XCTAssertTrue(FolderWorkspacePanel(defaults: defaults).roots.isEmpty)
    }

    func testLocateCurrentFileAndOpen() {
        let panel = FolderWorkspacePanel(defaults: defaults)
        panel.add([root])
        let file = root.appendingPathComponent("src/util/x.h")
        panel.currentFile = { file }
        XCTAssertTrue(panel.locateCurrentFile())
        let selected = panel.outline.item(atRow: panel.outline.selectedRow) as? FolderWorkspacePanel.Node
        XCTAssertEqual(selected?.url.standardizedFileURL, file.standardizedFileURL)
        var opened: URL?
        panel.onOpenFile = { opened = $0 }
        panel.openSelection(nil)
        XCTAssertEqual(opened?.standardizedFileURL, file.standardizedFileURL)
        panel.currentFile = { URL(fileURLWithPath: "/elsewhere/file.txt") }
        XCTAssertFalse(panel.locateCurrentFile())
    }

    func testRefreshSeesNewFilesAndKeepsFoldersOpen() throws {
        let panel = FolderWorkspacePanel(defaults: defaults)
        panel.add([root])
        let src = try XCTUnwrap(panel.roots[0].children.first { $0.name == "src" })
        panel.outline.expandItem(src)
        try Data("y".utf8).write(to: root.appendingPathComponent("src/new.c"))
        panel.refresh()
        let names = (0..<panel.outline.numberOfRows).compactMap { (panel.outline.item(atRow: $0) as? FolderWorkspacePanel.Node)?.name }
        XCTAssertTrue(names.contains("new.c"), "\(names)")
    }

    func testContextMenus() throws {
        let panel = FolderWorkspacePanel(defaults: defaults)
        panel.add([root])
        let menu = NSMenu()
        panel.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        panel.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first?.title, "Remove", "a root")
        XCTAssertTrue(menu.items.contains { $0.title == "Find in Files…" })
        let fileRow = (0..<panel.outline.numberOfRows).first { (panel.outline.item(atRow: $0) as? FolderWorkspacePanel.Node)?.name == "b.txt" }!
        panel.outline.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        panel.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first?.title, "Open", "a file")
        XCTAssertFalse(menu.items.contains { $0.title == "Find in Files…" })
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Path" })
        panel.copyPath(copy)
        XCTAssertEqual(AppEnvironment.pasteboard.string(forType: .string), root.appendingPathComponent("b.txt").standardizedFileURL.path)
    }

    func testTheWindowShowsThePanelOnTheLeft() {
        let window = MainWindowController()
        window.newTab()
        window.addWorkspaceFolders([root])
        XCTAssertTrue(window.isWorkspaceVisible)
        XCTAssertTrue(window.workspaceDock.isDescendant(of: window.leftDock))
        window.setWorkspaceVisible(false)
        window.workspace.removeAll()
        window.openTabs.forEach { $0.detach() }
    }
}
