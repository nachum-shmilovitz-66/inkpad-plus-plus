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

    /// MAC-72: `path` with every symlink resolved the way the kernel sees it — /etc/hosts is
    /// /private/etc/hosts. `URL.resolvingSymlinksInPath()` strips /private again (documented), and
    /// /etc itself is a link, so a folder opened from its result with O_NOFOLLOW fails. A final link
    /// is followed even when its target does not exist yet (the save creates it there).
    static func realPath(_ path: String) -> String {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            current = destination.hasPrefix("/") ? destination
                : URL(fileURLWithPath: current).deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        }
        if let resolved = realpath(current, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: current)
        guard let folder = realpath(url.deletingLastPathComponent().path, nil) else { return current }
        defer { free(folder) }
        return URL(fileURLWithPath: String(cString: folder)).appendingPathComponent(url.lastPathComponent).path
    }

    /// A real path as people write it: /private/etc/hosts reads /etc/hosts (MAC-72).
    static func displayPath(_ path: String) -> String {
        for link in ["/etc/", "/tmp/", "/var/"] where path.hasPrefix("/private" + link) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// `path` as written, with /etc → /private/etc, and every symlink on the way followed — also
    /// a link whose target does not exist yet (the save would create it there).
    static func isProtected(_ path: String) -> Bool {
        var candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path, realPath(path)]
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

    /// MAC-57: every step works on descriptors, never on a path someone could swap meanwhile —
    /// the folder is opened once (and checked to be the one that was asked for), the temp file is
    /// created there exclusively and without following links, its owner and mode are set on the
    /// descriptor, and it is renamed over the target within that same folder.
    static func install(_ data: Data, atPath path: String) throws {
        try validate(path: path, size: data.count)
        let target = URL(fileURLWithPath: realPath(path))  // MAC-72: /private kept, so /etc is a real folder
        let folderPath = target.deletingLastPathComponent().path
        let name = target.lastPathComponent

        let folder = open(folderPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.io("Could not open \(folderPath): \(errnoText())") }
        defer { close(folder) }
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(folder, F_GETPATH, &opened) == 0,
              URL(fileURLWithPath: String(cString: opened)).standardizedFileURL.path
                == URL(fileURLWithPath: folderPath).standardizedFileURL.path else {
            throw Failure.io("\(folderPath) changed while saving.")
        }

        // The file being replaced, as it is now in that folder — never through a link.
        var existing = stat()
        let replacing = fstatat(folder, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if replacing && (existing.st_mode & S_IFMT) != S_IFREG {
            throw Failure.invalidPath("it is not a regular file (it may have changed while saving)")
        }

        let tempName = ".\(name).macpad-save.\(UUID().uuidString)"
        let fd = openat(folder, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("Could not write a temporary file in \(folderPath): \(errnoText())") }
        var renamed = false
        defer { if !renamed { unlinkat(folder, tempName, 0) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Failure.io("Could not write the temporary file: \(errnoText())")
                    }
                    offset += written
                }
            }
            if replacing {
                // Same owner and group as the original. The temp file's group comes from the folder,
                // so compare with the temp file itself; when they already match there is nothing to do.
                var temp = stat()
                guard fstat(fd, &temp) == 0 else { throw Failure.io("Could not read the temporary file: \(errnoText())") }
                if (temp.st_uid != existing.st_uid || temp.st_gid != existing.st_gid),
                   fchown(fd, existing.st_uid, existing.st_gid) != 0 {
                    throw Failure.io("Could not give the new file the original's owner: \(errnoText())")
                }
                guard fchmod(fd, existing.st_mode & 0o7777) == 0 else {
                    throw Failure.io("Could not give the new file the original's permissions: \(errnoText())")
                }
            } else {
                guard fchmod(fd, 0o644) == 0 else { throw Failure.io("Could not set the new file's permissions: \(errnoText())") }
            }
        }
        guard renameat(folder, tempName, folder, name) == 0 else {
            throw Failure.io("Could not replace \(target.path): \(errnoText())")
        }
        renamed = true
    }

    /// MAC-57: the password route runs this as root (`MacPadHelper --install-file`). The source
    /// is the user's own temp copy; it is read only if it is still that — a regular file, not a
    /// link, owned by `owner`, with one name — so root never copies some other file into the target.
    static func installFile(source: String, target: String, owner: uid_t) throws {
        let fd = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io("Could not read the document to save: \(errnoText())") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == owner, info.st_nlink == 1 else {
            throw Failure.io("The document to save is not the file MacPad++ wrote.")
        }
        guard Int(info.st_size) <= maximumSize else { throw Failure.tooLarge(Int(info.st_size)) }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        try install(data, atPath: target)
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
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
    /// Could not do it (no right installed, not authorized): the app may try the password prompt.
    case failed = 3
    /// MAC-72: authorized, but the write itself failed. The app reports it and does not prompt again.
    case writeFailed = 4
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
        let target = FileInstaller.displayPath(FileInstaller.realPath(path))
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
            // MAC-72: authorized, then the write failed: report it; asking again would not help.
            return (.writeFailed, error.localizedDescription)
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
