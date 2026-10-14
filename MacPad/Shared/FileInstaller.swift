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
        case protectedPath(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let why): return "Not a file path that can be saved: \(why)"
            case .tooLarge(let bytes): return "The document is too large to save this way (\(bytes) bytes)."
            case .io(let message): return message
            case .protectedPath(let path):
                return "MacPad++ does not save \(path) as administrator: it is a system startup or security file. Use Terminal if you really mean to change it."
            }
        }
    }

    /// MAC-55: files that start programs as root or decide who may become root. Writing them is
    /// how a compromised process would make itself permanent, so the helper never does, whoever asks.
    static let protectedPrefixes = [
        "/System/", "/Library/LaunchDaemons/", "/Library/LaunchAgents/", "/Library/PrivilegedHelperTools/",
        "/Library/StartupItems/", "/Library/Security/", "/private/etc/sudoers", "/private/etc/pam.d/",
        "/private/etc/periodic/", "/private/var/root/", "/private/var/db/",
    ]

    /// `path` as written, with /etc → /private/etc, and every symlink on the way followed — also
    /// a link whose target does not exist yet (the save would create it there).
    static func isProtected(_ path: String) -> Bool {
        var candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        var current = path
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            current = destination.hasPrefix("/") ? destination
                : URL(fileURLWithPath: current).deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
            candidates += [current, URL(fileURLWithPath: current).resolvingSymlinksInPath().path]
        }
        return candidates.contains { candidate in
            for spelled in [candidate, candidate.hasPrefix("/etc/") ? "/private" + candidate : candidate] {
                if protectedPrefixes.contains(where: { spelled.hasPrefix($0) || spelled + "/" == $0 }) { return true }
            }
            return false
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
        guard !isProtected(path) else { throw Failure.protectedPath(path) }
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
    /// Where the installer's postinstall writes the helper's launchd plist (MAC-28).
    static let daemonPlistPath = "/Library/LaunchDaemons/app.macpad.MacPad.helper.plist"
    static let teamID = "96Y4LX7FVB"
    static let appIdentifier = "app.macpad.MacPad"
    /// Bumped when the protocol changes, so the app can tell a stale helper from a current one.
    /// 2 (MAC-55): every install carries an authorization the helper checks itself.
    static let helperVersion = "2"

    /// MAC-55: the authorization right each save needs — an administrator, asked every time.
    /// postinstall writes it into the authorization database; the helper refuses to work without it.
    static let saveRight = "app.macpad.MacPad.save"

    /// The text of the administrator prompt, naming the file the helper will actually write.
    static func prompt(forPath path: String) -> String {
        "MacPad++ wants to save \u{201C}\(path)\u{201D} as administrator."
    }

    /// A Developer ID signature of this team (MAC-55): Apple's Developer ID markers, so a build
    /// signed with the team's Apple Development certificate does not pass.
    private static var developerID: String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The helper accepts connections only from MacPad++ signed with this team's Developer ID.
    static var clientRequirement: String { "\(developerID) and identifier \"\(appIdentifier)\"" }

    /// MacPad++ talks only to a helper signed by the same team.
    static var helperRequirement: String { "\(developerID) and identifier \"\(machService)\"" }
}

/// How the helper answers an install (MAC-55).
@objc enum HelperReply: Int {
    case saved = 0
    /// The user cancelled the administrator prompt: nothing written, nothing else to try.
    case cancelled = 1
    /// Refused whatever the user says (a protected file, a bad request).
    case refused = 2
    /// Could not do it (no right installed, I/O error): the app may try the password prompt.
    case failed = 3
}

/// Checks that an administrator authorized this one write (MAC-55). The helper's implementation
/// asks Authorization Services; tests substitute their own.
protocol RequestAuthorizer {
    /// Throws `RequestAuthorization.cancelled` when the user cancels, anything else when it fails.
    func authorize(_ externalForm: Data, path: String) throws
}

enum RequestAuthorization: Error, Equatable {
    case cancelled
    case denied(String)
}

/// What the helper does with one request: check it, ask for the authorization (only for a request
/// it would carry out), then write. Shared so the tests run exactly what root runs.
enum HelperRequest {
    static func handle(_ data: Data, path: String, authorization: Data, authorizer: RequestAuthorizer,
                       install: (Data, String) throws -> Void = FileInstaller.install) -> (HelperReply, String?) {
        do {
            try FileInstaller.validate(path: path, size: data.count)
        } catch {
            return (.refused, error.localizedDescription)
        }
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        do {
            try authorizer.authorize(authorization, path: target)
        } catch RequestAuthorization.cancelled {
            return (.cancelled, nil)
        } catch {
            return (.failed, "Not authorized: \(error)")
        }
        do {
            try install(data, path)
            return (.saved, nil)
        } catch {
            return (.failed, error.localizedDescription)
        }
    }
}

/// The helper's XPC interface: one operation.
@objc(MacPadHelperProtocol)
protocol MacPadHelperProtocol {
    /// Installs `data` at `path` as root, once `authorization` (an AuthorizationExternalForm from
    /// the app) holds the save right — the helper asks the administrator for it. Replies with the
    /// outcome and, when it failed, a message.
    func install(_ data: Data, atPath path: String, authorization: Data,
                 withReply reply: @escaping (HelperReply, String?) -> Void)
    /// The helper's version, to tell a stale helper from a current one.
    func version(withReply reply: @escaping (String) -> Void)
}
