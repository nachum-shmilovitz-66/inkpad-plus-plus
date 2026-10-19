import AppKit

/// MAC-75: the AppKit side of Check for Updates — the menu command, the daily automatic check,
/// the offer (Download and Install / Later / Skip This Version), download progress, and handing
/// the verified package to Installer. The decisions are `Updater`'s.
final class UpdateController: NSObject {
    static let shared = UpdateController()

    let updater: Updater
    var policy = UpdateInstallPolicy.forApp(named: AppName.display)
    private var checking = false
    private var download: Task<Void, Never>?
    private var progressPanel: NSPanel?
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init(updater: Updater = Updater(network: URLSessionUpdateNetwork(version: UpdateController.currentVersion),
                                    defaults: AppEnvironment.defaults, currentVersion: UpdateController.currentVersion)) {
        self.updater = updater
    }

    /// Automatic checks run only in a Release build that is not the tests' host: Debug builds and
    /// tests never reach GitHub by themselves.
    static var automaticChecksAllowed: Bool {
        #if DEBUG
        return false
        #else
        return !AppEnvironment.isRunningTests
        #endif
    }

    /// At launch: a check when one is due, then a look every few hours while the app stays open.
    func startAutomaticChecks() {
        guard Self.automaticChecksAllowed else { return }
        updater.cleanUpOldDownloads()
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    func checkIfDue() {
        guard Preferences.current.checkForUpdatesAutomatically, updater.isAutomaticCheckDue() else { return }
        check(userInitiated: false)
    }

    /// Asks GitHub; an automatic check speaks only when there is a new, unskipped version.
    func check(userInitiated: Bool) {
        if download != nil {
            if userInitiated { progressPanel?.makeKeyAndOrderFront(nil) }
            return
        }
        guard !checking else { return }
        checking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            do {
                switch try await self.updater.check() {
                case .available(let update): self.offer(update)
                case .skipped(let update): if userInitiated { self.offer(update) }
                case .upToDate(let current): if userInitiated { self.showUpToDate(current) }
                }
            } catch {
                AppEnvironment.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated { self.showError(error, title: "Could not check for updates") }
            }
        }
    }

    // MARK: - Alerts

    private func showUpToDate(_ current: String) {
        let alert = NSAlert()
        alert.messageText = "You’re up to date!"
        alert.informativeText = "\(AppName.display) \(current) is the newest version available."
        alert.runModal()
    }

    private func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func offer(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "A new version of \(UpdateSource.publicName) is available"
        let installs = policy == .install && update.asset != nil
        var info = "\(UpdateSource.publicName) \(update.versionString) is available — you have \(Self.currentVersion)."
        if !installs {
            info += policy == .notifyOnly
                ? "\n\nThis copy is named \(AppName.display), and published installers are \(UpdateSource.publicName): get the update from its page."
                : "\n\nThe release has no installer for this Mac yet."
        }
        alert.informativeText = info
        alert.accessoryView = Self.notesView(update.notes)
        alert.addButton(withTitle: installs ? "Download and Install" : "View Release Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installs { downloadAndInstall(update) } else { NSWorkspace.shared.open(update.pageURL) }
        case .alertThirdButtonReturn:
            updater.skip(update)
        default:
            break
        }
    }

    /// The release notes, read-only and scrollable.
    static func notesView(_ notes: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.string = notes.isEmpty ? "No release notes." : notes
        }
        return scroll
    }

    // MARK: - Download and install

    private func downloadAndInstall(_ update: AvailableUpdate) {
        showProgress("Downloading \(UpdateSource.publicName) \(update.versionString)…")
        download = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.download = nil; self.closeProgress() }
            do {
                let package = try await self.updater.downloadAndVerify(update)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()); return }
                self.closeProgress()
                self.openInInstaller(package)
            } catch {
                guard !Task.isCancelled else { return }
                AppEnvironment.log.error("Update download failed: \(error.localizedDescription, privacy: .public)")
                self.closeProgress()
                self.showError(error, title: "The update could not be installed")
            }
        }
    }

    /// Always Apple's Installer, whatever app the user associated with .pkg files. Its must-close
    /// step asks to quit MacPad++ (which then asks about unsaved documents) before installing.
    private func openInInstaller(_ package: URL) {
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        NSWorkspace.shared.open([package], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.showError(error, title: "Installer could not be opened") }
        }
    }

    private func showProgress(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Software Update"
        let label = NSTextField(labelWithString: message)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel
    }

    private func closeProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
    }

    @objc func cancelDownload(_ sender: Any?) {
        download?.cancel()
        download = nil
        closeProgress()
    }
}
