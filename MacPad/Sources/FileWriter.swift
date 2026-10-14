import Foundation

/// How MacPad++ writes a document back (MAC-61, MAC-62): through a symlink to the file it points
/// at — the link stays a link — keeping that file's permissions, and in place when the file has
/// more than one hard link, so every name keeps seeing the same file (as Notepad++ does). Any
/// other file is replaced atomically.
enum FileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        var info = stat()
        let exists = stat(target.path, &info) == 0
        if exists && info.st_nlink > 1 && (info.st_mode & S_IFMT) == S_IFREG {
            let handle = try FileHandle(forUpdating: target)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            return
        }
        try data.write(to: target, options: .atomic)
        if exists {
            chmod(target.path, info.st_mode & 0o7777)  // the file's own mode, never a link's 0755
        }
    }
}
