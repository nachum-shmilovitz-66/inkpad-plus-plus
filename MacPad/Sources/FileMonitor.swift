import Foundation

// Watching a file on disk: Notepad++'s Monitoring (tail -f), and the base for File Status
// Auto-Detection (MAC-20). Classification and decoding are pure and unit-tested; FileWatcher is
// the thin kqueue/timer layer that says "look again".

/// What identifies a file's state between two looks at it.
struct FileSnapshot: Equatable {
    var inode: UInt64
    /// For a monitored file: the number of bytes already read into the editor.
    var size: UInt64
    var modified: TimeInterval

    init(inode: UInt64, size: UInt64, modified: TimeInterval) {
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    /// The file's current state, or nil if it does not exist (deleted, or mid-rotation).
    static func of(path: String) -> FileSnapshot? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return FileSnapshot(inode: UInt64(info.st_ino), size: UInt64(info.st_size), modified: mtime)
    }
}

/// How a file changed since the last look.
enum FileChange: Equatable {
    case unchanged
    /// Same file, longer: only the bytes from `from` on are new (a log being written).
    case appended(from: UInt64)
    /// Replaced (log rotation, an editor's atomic save), truncated, rewritten in place, or back
    /// after being missing: everything must be read again.
    case replaced
    /// Gone (deleted, or renamed away and not yet recreated).
    case missing

    static func classify(previous: FileSnapshot?, current: FileSnapshot?) -> FileChange {
        guard let current else { return previous == nil ? .unchanged : .missing }
        guard let previous else { return .replaced }
        if current.inode != previous.inode { return .replaced }
        if current.size > previous.size { return .appended(from: previous.size) }
        if current.size < previous.size { return .replaced }
        return current.modified != previous.modified ? .replaced : .unchanged
    }
}

/// Turns bytes appended to a file, in the file's encoding, into UTF-8 for Scintilla — holding back
/// a character whose bytes are split across two writes until the rest arrives.
struct IncrementalDecoder {
    let encoding: TextEncoding
    private(set) var pending = Data()

    init(encoding: TextEncoding) { self.encoding = encoding }

    mutating func reset() { pending = Data() }

    mutating func feed(_ bytes: Data) -> Data {
        var data = pending
        data.append(bytes)
        if case .codePage(let cp) = encoding { return feedCodePage(cp, data) }
        let cut: Int
        switch encoding {
        case .utf8, .utf8BOM: cut = Self.completeUTF8Prefix(data)
        case .utf16LE, .utf16BE: cut = Self.completeUTF16Prefix(data, littleEndian: encoding == .utf16LE)
        case .ansi, .codePage: cut = data.count
        }
        let complete = Data(data.prefix(cut))
        pending = Data(data.dropFirst(cut))
        switch encoding {
        case .utf8, .utf8BOM:
            return complete
        case .utf16LE, .utf16BE:
            return Data(Self.utf16Units(complete, littleEndian: encoding == .utf16LE)
                .withUnsafeBufferPointer { String(decoding: $0, as: UTF16.self) }.utf8)
        case .ansi, .codePage:
            let text = String(data: complete, encoding: .windowsCP1252)
                ?? String(data: complete, encoding: .isoLatin1) ?? ""
            return Data(text.utf8)
        }
    }

    /// Legacy code pages: single-byte ones always decode; for double-byte ones (Shift-JIS, GBK,
    /// Big5, EUC-KR…) a trailing lead byte waits for its partner.
    private mutating func feedCodePage(_ cp: Int, _ data: Data) -> Data {
        pending = Data()
        guard let e = TextEncoding.stringEncoding(forCodePage: cp) else {
            return Data((String(data: data, encoding: .isoLatin1) ?? "").utf8)
        }
        if let text = String(data: data, encoding: e) { return Data(text.utf8) }
        if data.count > 1, let text = String(data: data.dropLast(), encoding: e) {
            pending = Data(data.suffix(1))
            return Data(text.utf8)
        }
        if data.count == 1 { pending = data; return Data() }
        return Data((String(data: data, encoding: .isoLatin1) ?? "").utf8)  // bytes the code page rejects
    }

    /// Length of the prefix that ends on a UTF-8 character boundary. Invalid bytes count as
    /// complete (they are passed through, as on load), so nothing is ever held back for long.
    static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        let base = data.count - bytes.count
        // Find the last lead byte (not 10xxxxxx) within the final 4 bytes.
        guard let i = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return data.count }
        let lead = bytes[i]
        let needed: Int
        switch lead {
        case 0x00...0x7F: return data.count
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default: return data.count
        }
        return bytes.count - i < needed ? base + i : data.count
    }

    /// Length of the prefix made of whole UTF-16 code units, not ending in a high surrogate.
    static func completeUTF16Prefix(_ data: Data, littleEndian: Bool) -> Int {
        var cut = data.count - data.count % 2
        if cut >= 2 {
            let bytes = [UInt8](data[data.startIndex + cut - 2 ..< data.startIndex + cut])
            let unit = littleEndian ? UInt16(bytes[0]) | UInt16(bytes[1]) << 8 : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            if (0xD800...0xDBFF).contains(unit) { cut -= 2 }
        }
        return cut
    }

    private static func utf16Units(_ data: Data, littleEndian: Bool) -> [UInt16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { i in
            littleEndian ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
        }
    }
}

/// Calls `onChange` on the main queue whenever the file at `path` may have changed: immediately
/// for writes (kqueue), and on a short poll that also catches the file being replaced or recreated
/// (log rotation), which a descriptor on the old file cannot see.
final class FileWatcher {
    let path: String
    private let pollInterval: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    init(path: String, pollInterval: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.path = path
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        armSource()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.source == nil { self.armSource() }  // recreated after rotation
            self.onChange()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    private func armSource() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                // The descriptor now follows the old file; drop it and re-open on the next poll.
                source.cancel()
                self.source = nil
            }
            self.onChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}
