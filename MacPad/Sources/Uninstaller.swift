import AppKit

/// MacPad++ › Uninstall MacPad++… (MAC-53): runs the bundled uninstall.sh as root through the
/// administrator prompt (it removes the app, the helper's LaunchDaemon, the `macpad` link and the
/// package receipt), optionally removes the user's own settings, then quits.
struct Uninstaller {
    /// Only the installed release uninstalls: a Debug build would remove its build folder and the
    /// real helper of the installed copy.
    static let releaseIdentifier = "app.macpad.MacPad"

    var bundleIdentifier: String? = Bundle.main.bundleIdentifier
    var appURL: URL = Bundle.main.bundleURL
    var scriptURL: URL? = Bundle.main.url(forResource: "uninstall", withExtension: "sh")
    var runner: PrivilegedRunner = PrivilegedSave.runner
    var supportDirectory: URL = AppEnvironment.supportDirectory
    /// The preferences domain removed with "Also remove my settings": the app's own, or the
    /// isolated test suite — never a name a test passes in for the release.
    var preferencesDomain: String? = AppEnvironment.isRunningTests ? nil : Bundle.main.bundleIdentifier

    var isAvailable: Bool {
        bundleIdentifier == Self.releaseIdentifier && appURL.lastPathComponent == "MacPad++.app" && scriptURL != nil
    }

    /// The root command: the script, given the app to remove (both quoted for /bin/sh).
    func command() -> String? {
        guard let scriptURL else { return nil }
        return "/bin/sh \(PrivilegedSave.shellQuote(scriptURL.path)) \(PrivilegedSave.shellQuote(appURL.path))"
    }

    static let prompt = "MacPad++ needs administrator rights to uninstall itself."

    /// Runs the uninstaller; `removeSettings` also deletes the user's MacPad++ settings
    /// (Application Support/MacPad++ and the preferences), which root's script leaves alone.
    func run(removeSettings: Bool) throws {
        guard isAvailable, let command = command() else { throw PrivilegedSaveError.failed("this copy of MacPad++ cannot uninstall itself") }
        try runner.run(shellScript: command, prompt: Self.prompt)
        if removeSettings {
            try? FileManager.default.removeItem(at: supportDirectory)
            if let preferencesDomain { UserDefaults.standard.removePersistentDomain(forName: preferencesDomain) }
        }
    }

    /// The confirmation, with the settings checkbox: nil when cancelled, else whether to remove
    /// the settings too.
    @MainActor
    static func confirm() -> Bool? {
        let alert = NSAlert()
        alert.messageText = "Uninstall MacPad++?"
        alert.informativeText = "This removes MacPad++ from Applications, its helper for administrator saves, "
            + "the macpad command-line tool and the installer receipt, then quits. "
            + "You are asked about unsaved documents first."
        alert.alertStyle = .warning
        let settings = NSButton(checkboxWithTitle: "Also remove my settings (themes, macros, session, preferences)",
                                target: nil, action: nil)
        alert.accessoryView = settings
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return settings.state == .on
    }
}
