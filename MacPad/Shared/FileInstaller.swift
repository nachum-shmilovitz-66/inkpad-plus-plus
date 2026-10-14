import Foundation

// Shared by MacPad++ and its privileged helper (MAC-24). The helper runs this as root; the app's
// tests run it as the user on temp files, so what root executes is exactly what is tested.

/// Writes bytes over a file the way MAC-22's admin script does: a temp file beside the target,
/// the target's owner, group and mode copied onto it (a new file gets 0644), then an atomic
/// rename — the file is replaced whole or not at all. Symlinks are resolved first, so a linked
/// file is updated rather than replaced by a regular file.
enum FileInstaller {
    enum Failure: LocalizedError, Equatable {
        case invalidPath(String)
        case tooLarge(Int)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let why): return "Not a file path that can be saved: \(why)"
            case .tooLarge(let bytes): return "The document is too large to save this way (\(bytes) bytes)."
            case .io(let message): return message
            }
        }
    }

    /// The helper writes nothing larger than this (a text editor's document, not arbitrary data).
    static let maximumSize = 512 * 1024 * 1024

    /// Checks a request before anything touches the disk.
    static func validate(path: String, size: Int) throws {
        guard !path.isEmpty, path.hasPrefix("/") else { throw Failure.invalidPath("it must be an absolute path") }
        guard !path.hasSuffix("/") else { throw Failure.invalidPath("it names a folder") }
        guard !path.contains("\0") else { throw Failure.invalidPath("it contains a NUL character") }
        guard size <= maximumSize else { throw Failure.tooLarge(size) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw Failure.invalidPath("it is a folder")
        }
    }

    static func install(_ data: Data, atPath path: String) throws {
        try validate(path: path, size: data.count)
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).macpad-save.\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.io("Could not write a temporary file in \(target.deletingLastPathComponent().path).")
        }
        defer { try? fm.removeItem(at: temp) }  // gone after the rename; cleans up after a failure

        do {
            if let existing = try? fm.attributesOfItem(atPath: target.path) {
                var keep: [FileAttributeKey: Any] = [:]
                keep[.ownerAccountID] = existing[.ownerAccountID]
                keep[.groupOwnerAccountID] = existing[.groupOwnerAccountID]
                keep[.posixPermissions] = existing[.posixPermissions]
                try fm.setAttributes(keep, ofItemAtPath: temp.path)
            } else {
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path)
            }
        } catch {
            throw Failure.io("Could not give the new file the original's owner and permissions: \(error.localizedDescription)")
        }
        guard rename(temp.path, target.path) == 0 else {
            throw Failure.io("Could not replace \(target.path): \(String(cString: strerror(errno)))")
        }
    }
}

/// What MacPad++ and its helper agree on (names, and who may talk to whom).
enum HelperIdentity {
    static let machService = "app.macpad.MacPad.helper"
    static let daemonPlist = "app.macpad.MacPad.helper.plist"
    static let teamID = "96Y4LX7FVB"
    static let appIdentifier = "app.macpad.MacPad"
    /// Bumped when the protocol changes, so the app can tell a stale helper from a current one.
    static let helperVersion = "1"

    /// The helper accepts connections only from MacPad++ signed with this team's Developer ID.
    static var clientRequirement: String {
        "anchor apple generic and identifier \"\(appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// MacPad++ talks only to a helper signed by the same team.
    static var helperRequirement: String {
        "anchor apple generic and identifier \"\(machService)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// The helper's XPC interface: one operation.
@objc(MacPadHelperProtocol)
protocol MacPadHelperProtocol {
    /// Installs `data` at `path` as root. Replies nil on success, or an error message.
    func install(_ data: Data, atPath path: String, withReply reply: @escaping (String?) -> Void)
    /// The helper's version, to tell a stale helper from a current one.
    func version(withReply reply: @escaping (String) -> Void)
}
