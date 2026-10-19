import Foundation

// Save as Administrator (MAC-22): when a file cannot be written for lack of permission
// (/etc/hosts, files under /Library…), write it with the standard macOS administrator prompt.
//
// The bytes are written to a private temp file as the user; then one small shell script runs as
// root: it copies them next to the target, gives the copy the target's owner, group and mode, and
// renames it over the target — so the file is replaced whole or not at all, never left partial.
// Inkpad++ never sees the password: macOS's own authorization dialog handles it.

enum PrivilegedSaveError: LocalizedError, Equatable {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Saving as administrator was cancelled."
        case .failed(let message): return "Saving as administrator failed: \(message)"
        }
    }
}

/// Runs a shell script as root. The app uses the macOS admin prompt; tests substitute a runner.
protocol PrivilegedRunner {
    func run(shellScript: String, prompt: String) throws
}

/// `do shell script … with administrator privileges`: macOS shows its own password / Touch ID
/// dialog and runs the script as root.
struct AdminPromptRunner: PrivilegedRunner {
    func run(shellScript: String, prompt: String) throws {
        var errorInfo: NSDictionary?
        let source = PrivilegedSave.appleScript(shell: shellScript, prompt: prompt)
        guard let script = NSAppleScript(source: source) else { throw PrivilegedSaveError.failed("could not prepare the request") }
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -128 { throw PrivilegedSaveError.cancelled }  // userCanceledErr
        throw PrivilegedSaveError.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }
}

enum PrivilegedSave {
    /// The runner used by the app; tests replace it.
    static var runner: PrivilegedRunner = AdminPromptRunner()

    /// A failure administrator rights can get past: no permission on the file or its folder.
    /// A read-only volume is not one (root cannot write it either).
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    /// Single-quotes `s` for /bin/sh (a ' inside becomes '\'').
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The root command (MAC-57): Inkpad++'s helper binary, run once, does the write with the same
    /// descriptor-based code the helper daemon uses — no shell temp files, nothing followed through
    /// links, and the user's copy read only if it is still the user's own file.
    static func installScript(source: String, target: String, owner: uid_t = getuid(),
                              helper: String = PrivilegedSave.helperPath) -> String {
        "exec \(shellQuote(helper)) --install-file \(shellQuote(source)) \(shellQuote(target)) \(owner)"
    }

    static var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/InkpadHelper").path }

    /// Escapes for an AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func appleScript(shell: String, prompt: String) -> String {
        "do shell script \(appleScriptString(shell)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    /// The full path, so the administrator sees exactly which file is written (MAC-55).
    static func prompt(for target: URL) -> String {
        "\(AppName.display) needs administrator rights to save \u{201C}\(target.path)\u{201D}."
    }

    /// Writes `data` to `target` as root. Symlinks are resolved first, so a linked file is updated
    /// instead of being replaced by a regular file.
    static func save(_ data: Data, to target: URL, runner: PrivilegedRunner = PrivilegedSave.runner) throws {
        let resolved = target.resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inkpad++-admin-save-\(UUID().uuidString)")
        try data.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        defer { try? FileManager.default.removeItem(at: temp) }
        try runner.run(shellScript: installScript(source: temp.path, target: resolved.path),
                       prompt: prompt(for: resolved))
    }
}
