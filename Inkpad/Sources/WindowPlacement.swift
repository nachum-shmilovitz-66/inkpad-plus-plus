import AppKit

/// Where the main window opens (MAC-26), following macOS convention: the first time, centered on
/// the main screen — a little above the middle, as NSWindow.center() does — at a size that suits
/// the screen; after that, where the user left it, as long as that is still on a connected screen.
enum WindowPlacement {
    static let autosaveName = "Inkpad++ Main Window"
    static let minimumSize = NSSize(width: 600, height: 400)

    /// Comfortable for an editor: about 60% of the screen's width and 80% of its height, never
    /// below 900 × 600 nor beyond 90% of the screen.
    static func defaultFrame(in visible: NSRect) -> NSRect {
        let width = min(max(visible.width * 0.6, 900), visible.width * 0.9)
        let height = min(max(visible.height * 0.8, 600), visible.height * 0.95)
        let freeHeight = visible.height - height
        return NSRect(x: (visible.midX - width / 2).rounded(),
                      y: (visible.minY + freeHeight * 0.6).rounded(),  // more room below than above
                      width: width.rounded(), height: height.rounded())
    }

    /// A saved frame is kept only if a reasonable part of its title bar is on a connected screen
    /// (so the window can still be grabbed); otherwise the default frame on the main screen.
    static func frame(saved: NSRect?, screens: [NSRect], main: NSRect) -> NSRect {
        guard let saved, saved.width >= minimumSize.width, saved.height >= minimumSize.height else {
            return defaultFrame(in: main)
        }
        let titleBar = NSRect(x: saved.minX, y: saved.maxY - 28, width: saved.width, height: 28)
        let visibleTitle = screens.reduce(0) { best, screen in
            let overlap = titleBar.intersection(screen)
            return max(best, overlap.isNull ? 0 : overlap.width)
        }
        return visibleTitle >= min(120, saved.width / 2) ? saved : defaultFrame(in: main)
    }

    /// AppKit's saved form, "x y width height screenX screenY screenWidth screenHeight": the
    /// window frame is the first four numbers.
    static func savedFrame(from string: String?) -> NSRect? {
        guard let parts = string?.split(separator: " ").compactMap({ Double($0) }), parts.count >= 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// Applies the placement to the main window and keeps it saved from now on — except in the
    /// unit tests' host, which must not move the user's window (MAC-23).
    static func place(_ window: NSWindow) {
        window.contentMinSize = minimumSize
        let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = AppEnvironment.isRunningTests
            ? nil : savedFrame(from: UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)"))
        let screens = NSScreen.screens.map(\.visibleFrame)
        window.setFrame(frame(saved: saved, screens: screens, main: main), display: false)
        if !AppEnvironment.isRunningTests { window.setFrameAutosaveName(autosaveName) }
    }
}
