import AppKit

/// The menu bar, built in code (no nib). Edit actions go to the first responder, which is
/// Scintilla's content view: it implements undo:, redo:, cut:, copy:, paste:, clear:, selectAll:.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(searchMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(languageMenu()))
        main.addItem(submenu(settingsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MacPad++")
        menu.addItem(item("About MacPad++", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide MacPad++", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit MacPad++", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(AppDelegate.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Recent Files")
        recent.delegate = AppDelegate.shared
        let recentItem = NSMenuItem(title: "Recent Files", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(item("Save", #selector(MainWindowController.saveDocument(_:)), "s"))
        menu.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", Selector(("clear:"))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// Notepad++'s Search menu with Mac shortcuts: ⌘F Find, ⌥⌘F Replace (Ctrl+H is Hide on a Mac),
    /// ⇧⌘M Mark (⌘M is Minimize), ⌥⌘I Incremental Search, ⌘L Go To (⌘G is Find Next),
    /// ⌘G / ⇧⌘G for F3 / Shift+F3, ⌥⌘G / ⌥⇧⌘G for Ctrl+F3 / Ctrl+Shift+F3, ⌘E Use Selection for Find.
    private static func searchMenu() -> NSMenu {
        let menu = NSMenu(title: "Search")
        menu.addItem(item("Find…", #selector(AppDelegate.showFindPanel(_:)), "f"))
        menu.addItem(item("Find Next", #selector(AppDelegate.findNextMatch(_:)), "g"))
        menu.addItem(item("Find Previous", #selector(AppDelegate.findPreviousMatch(_:)), "g", [.command, .shift]))
        menu.addItem(item("Select and Find Next", #selector(AppDelegate.selectAndFindNext(_:)), "g", [.command, .option]))
        menu.addItem(item("Select and Find Previous", #selector(AppDelegate.selectAndFindPrevious(_:)), "g", [.command, .option, .shift]))
        menu.addItem(item("Use Selection for Find", #selector(AppDelegate.useSelectionForFind(_:)), "e"))
        menu.addItem(item("Incremental Search", #selector(MainWindowController.showIncrementalSearch(_:)), "i", [.command, .option]))
        menu.addItem(item("Go To…", #selector(AppDelegate.showGoTo(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Replace…", #selector(AppDelegate.showReplacePanel(_:)), "f", [.command, .option]))
        menu.addItem(item("Find in Files…", #selector(AppDelegate.showFindInFilesPanel(_:)), "f", [.command, .shift]))
        menu.addItem(item("Mark…", #selector(AppDelegate.showMarkPanel(_:)), "m", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Search Results Window", #selector(MainWindowController.toggleSearchResultsWindow(_:)), functionKey(NSF7FunctionKey), []))
        menu.addItem(item("Next Search Result", #selector(MainWindowController.nextSearchResult(_:)), functionKey(NSF4FunctionKey), []))
        menu.addItem(item("Previous Search Result", #selector(MainWindowController.previousSearchResult(_:)), functionKey(NSF4FunctionKey), .shift))
        menu.addItem(.separator())
        menu.addItem(styleSubmenu("Style All Occurrences of Token", #selector(MainWindowController.styleAllOccurrences(_:)), styles))
        menu.addItem(styleSubmenu("Style One Token", #selector(MainWindowController.styleOneToken(_:)), styles))
        menu.addItem(styleSubmenu("Clear Style", #selector(MainWindowController.clearStyle(_:)), styles + [(5, "Clear all Styles")]))
        menu.addItem(styleSubmenu("Jump Up", #selector(MainWindowController.jumpUp(_:)), styles + [(5, "Find Mark Style")],
                                  keys: [.command, .option]))
        menu.addItem(styleSubmenu("Jump Down", #selector(MainWindowController.jumpDown(_:)), styles + [(5, "Find Mark Style")],
                                  keys: .command))
        menu.addItem(styleSubmenu("Copy Styled Text", #selector(MainWindowController.copyStyledText(_:)),
                                  styles + [(5, "All Styles"), (6, "Find Mark Style")]))
        menu.addItem(.separator())
        let bookmark = NSMenuItem(title: "Bookmark", action: nil, keyEquivalent: "")
        bookmark.submenu = bookmarkMenu()
        menu.addItem(bookmark)
        return menu
    }

    private static let styles: [(Int, String)] = (0..<5).map { ($0, ["1st", "2nd", "3rd", "4th", "5th"][$0] + " Style") }

    /// A submenu of the five token styles (tags 0–4) plus extras. With `keys`, items get
    /// Notepad++'s Ctrl+1…5 / Ctrl+0 as ⌘ (or ⌥⌘) 1…5 / 0.
    private static func styleSubmenu(_ title: String, _ action: Selector, _ entries: [(Int, String)],
                                     keys: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for (tag, name) in entries {
            let key = keys == nil ? "" : (tag < 5 ? String(tag + 1) : "0")
            let entry = item(name, action, key, keys ?? .command)
            entry.tag = tag
            submenu.addItem(entry)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// Search › Bookmark, also shown by a right-click in the bookmark margin. Notepad++'s
    /// Ctrl+F2 / F2 / Shift+F2 are ⌘F2 / F2 / ⇧F2.
    private static func functionKey(_ key: Int) -> String { String(Character(Unicode.Scalar(UInt32(key))!)) }

    static func bookmarkMenu() -> NSMenu {
        let f2 = functionKey(NSF2FunctionKey)
        let menu = NSMenu(title: "Bookmark")
        menu.addItem(item("Toggle Bookmark", #selector(MainWindowController.toggleBookmark(_:)), f2, .command))
        menu.addItem(item("Next Bookmark", #selector(MainWindowController.nextBookmark(_:)), f2, []))
        menu.addItem(item("Previous Bookmark", #selector(MainWindowController.previousBookmark(_:)), f2, .shift))
        menu.addItem(item("Clear All Bookmarks", #selector(MainWindowController.clearAllBookmarks(_:))))
        menu.addItem(item("Cut Bookmarked Lines", #selector(MainWindowController.cutBookmarkedLines(_:))))
        menu.addItem(item("Copy Bookmarked Lines", #selector(MainWindowController.copyBookmarkedLines(_:))))
        menu.addItem(item("Paste to (Replace) Bookmarked Lines", #selector(MainWindowController.pasteToBookmarkedLines(_:))))
        menu.addItem(item("Remove Bookmarked Lines", #selector(MainWindowController.removeBookmarkedLines(_:))))
        menu.addItem(item("Remove Non-Bookmarked Lines", #selector(MainWindowController.removeUnbookmarkedLines(_:))))
        menu.addItem(item("Inverse Bookmark", #selector(MainWindowController.inverseBookmarks(_:))))
        return menu
    }

    /// Notepad++'s compact Language menu (letter submenus), generated from Notepad_plus.rc.
    static func languageMenu() -> NSMenu {
        let menu = NSMenu(title: "Language")
        func entry(_ title: String, _ language: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MainWindowController.selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = language
            return item
        }
        for e in languageMenuEntries {
            switch e {
            case .item(let title, let language): menu.addItem(entry(title, language))
            case .separator: menu.addItem(.separator())
            case .submenu(let title, let items):
                let sub = NSMenu(title: title)
                items.forEach { sub.addItem(entry($0.title, $0.language)) }
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
        return menu
    }

    /// Notepad++'s Settings menu. Preferences live in the app menu (⌘,) on a Mac.
    private static func settingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Settings")
        let theme = NSMenu(title: "Theme")
        theme.delegate = AppDelegate.shared  // rebuilt on open: themes can be added while running
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = theme
        menu.addItem(themeItem)
        menu.addItem(item("Style Configurator…", #selector(AppDelegate.showStyleConfigurator(_:))))
        return menu
    }

    /// The available themes, the selected one ticked, then the user themes folder.
    static func fillThemeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selected = ThemeManager.shared.selectedName
        for entry in ThemeManager.shared.available {
            let item = NSMenuItem(title: entry.name, action: #selector(AppDelegate.selectTheme(_:)), keyEquivalent: "")
            item.representedObject = entry.name
            item.state = entry.name == selected ? .on : .off
            menu.addItem(item)
            if entry.name == ThemeManager.defaultName { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Themes Folder…", action: #selector(AppDelegate.openThemesFolder(_:)), keyEquivalent: ""))
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom In", #selector(MainWindowController.zoomInText(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(MainWindowController.zoomOutText(_:)), "-"))
        menu.addItem(item("Restore Default Zoom", #selector(MainWindowController.restoreTextZoom(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Show All Characters", #selector(MainWindowController.toggleShowAllCharacters(_:))))
        menu.addItem(item("Word Wrap", #selector(MainWindowController.toggleWordWrap(_:))))
        menu.addItem(item("Monitoring (tail -f)", #selector(MainWindowController.toggleMonitoring(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "[", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
