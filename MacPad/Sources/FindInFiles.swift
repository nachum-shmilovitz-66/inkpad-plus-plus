import AppKit

// Find in Files / Replace in Files (MAC-33), ported from Notepad++'s getMatchedFileNames,
// findInFilelist and replaceInFilelist: the filter syntax, the folder walk, and the per-file
// search that reuses Find All and Replace All.

/// Notepad++'s Filters field: space-separated wildcards matched against the file name, ignoring
/// case. "!pattern" excludes files, "!\folder" excludes top-level folders and "!+\folder" folders
/// at any depth ("/" works as well as "\" on a Mac). Empty means "*.*", which matches every name.
/// Semicolons separate patterns too, as Windows' PathMatchSpec allows.
struct FileFilter: Equatable {
    private(set) var includes: [String] = []
    private(set) var excludes: [String] = []
    private(set) var topLevelFolderExcludes: [String] = []
    private(set) var anyDepthFolderExcludes: [String] = []

    /// What the field shows once validated: empty becomes "*.*".
    let text: String

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed.isEmpty ? "*.*" : trimmed
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map(String.init)
        for token in tokens {
            if token.count > 3, token.hasPrefix("!+\\") || token.hasPrefix("!+/") {
                anyDepthFolderExcludes.append(String(token.dropFirst(3)))
            } else if token.count > 2, token.hasPrefix("!\\") || token.hasPrefix("!/") {
                topLevelFolderExcludes.append(String(token.dropFirst(2)))
            } else if token.count > 1, token.hasPrefix("!") {
                excludes.append(String(token.dropFirst()))
            } else {
                includes.append(token)
            }
        }
        if includes.isEmpty { includes = ["*.*"] }  // only exclusions: everything else is in
    }

    func matchesFile(named name: String) -> Bool {
        if excludes.contains(where: { Self.wildcard($0, matches: name) }) { return false }
        return includes.contains { Self.wildcard($0, matches: name) }
    }

    /// `level` 1 is a folder directly inside the searched directory.
    func excludesFolder(named name: String, level: Int) -> Bool {
        anyDepthFolderExcludes.contains { Self.wildcard($0, matches: name) }
            || (level == 1 && topLevelFolderExcludes.contains { Self.wildcard($0, matches: name) })
    }

    /// PathMatchSpec: `*` and `?`, case-insensitive; "*.*" matches names without a dot too.
    static func wildcard(_ pattern: String, matches name: String) -> Bool {
        if pattern == "*.*" || pattern == "*" { return true }
        return fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }
}

/// The folder walk: depth-first, entries in name order (Windows' directory order is effectively
/// sorted; macOS gives none), hidden folders only when asked, hidden files always, symlinked
/// folders followed once.
enum FileCollector {
    /// Nil when cancelled.
    static func files(in root: URL, filter: FileFilter, recursive: Bool, includeHiddenFolders: Bool,
                      isCancelled: () -> Bool = { false }, found: (Int, URL) -> Void = { _, _ in }) -> [URL]? {
        var result: [URL] = []
        var visited = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]

        func walk(_ directory: URL, level: Int) -> Bool {
            guard !isCancelled() else { return false }
            guard visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return true }  // a link loop
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = entry.lastPathComponent
                // The path as the user typed the directory (macOS may hand back /private/var for /var).
                let url = directory.appendingPathComponent(name)
                let values = try? entry.resourceValues(forKeys: Set(keys))
                var isDirectory = values?.isDirectory ?? false
                if values?.isSymbolicLink == true {
                    var flag: ObjCBool = false
                    isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
                }
                if isDirectory {
                    let hidden = name.hasPrefix(".") || values?.isHidden == true
                    if hidden && !includeHiddenFolders { continue }
                    guard recursive, !filter.excludesFolder(named: name, level: level) else { continue }
                    if !walk(url, level: level + 1) { return false }
                } else if filter.matchesFile(named: name) {
                    result.append(url)
                    found(result.count, url)
                }
            }
            return true
        }

        return walk(root, level: 1) ? result : nil
    }
}

/// One Find in Files / Replace in Files run, done a few files at a time on the main thread
/// (Scintilla views belong to it) so the progress window stays live and Cancel works.
final class FindInFilesJob {
    enum Kind { case findAll, replace(String) }

    enum Outcome: Equatable {
        case found(SearchResultsBlock)
        case replaced(Int, failed: [String])
        case invalidRegex
        case cancelled
    }

    /// An open document for a file in the search: its buffer is searched (unsaved edits too), and
    /// a Replace in Files saves it, as Notepad++ does.
    struct OpenDocument {
        let editor: ScintillaView
        let save: () -> Void
    }

    let text: String
    let kind: Kind
    let options: SearchOptions
    let files: [URL]
    let openDocument: (URL) -> OpenDocument?
    private(set) var index = 0
    private(set) var hits = 0
    private(set) var isCancelled = false
    private var resultFiles: [SearchResultsFile] = []
    private var replaced = 0
    private var failed: [String] = []
    private lazy var scratch: ScintillaView = {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.send(SCI_SETUNDOCOLLECTION, 0)
        return v
    }()

    init(text: String, kind: Kind, options: SearchOptions, files: [URL], openDocument: @escaping (URL) -> OpenDocument? = { _ in nil }) {
        self.text = text
        self.kind = kind
        var opts = options
        opts.inSelection = false  // every file is searched whole
        opts.wrapAround = true
        self.options = opts
        self.files = files
        self.openDocument = openDocument
    }

    var currentFile: URL? { files.indices.contains(index) ? files[index] : nil }
    var isFinished: Bool { index >= files.count || isCancelled || stopped != nil }
    private var stopped: Outcome?

    func cancel() { isCancelled = true }

    /// Processes files for about `budget` seconds; true while more remain.
    @discardableResult
    func step(budget: TimeInterval = 0.05) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        while !isFinished {
            process(files[index])
            index += 1
            if Date() >= deadline { break }
        }
        return !isFinished
    }

    func runToCompletion() -> Outcome {
        while step(budget: 1) {}
        return outcome
    }

    var outcome: Outcome {
        if let stopped { return stopped }
        switch kind {
        case .findAll:
            let header = SearchResultsFormat.searchHeader(term: text, hits: hits, files: resultFiles.count,
                                                          searched: files.count, inSelection: false, options: options)
            return .found(SearchResultsBlock(header: header, files: resultFiles, hitCount: hits))
        case .replace:
            return .replaced(replaced, failed: failed)  // a cancelled run reports what it did
        }
    }

    private func process(_ url: URL) {
        let open = openDocument(url)
        let editor: ScintillaView
        var loadedEncoding: TextEncoding?
        if let open {
            editor = open.editor
        } else {
            guard let data = try? Data(contentsOf: url) else { return }  // unreadable: skipped, as in Notepad++
            let loaded = TextFile.decode(data)
            scratch.setUTF8Bytes(loaded.utf8)
            loadedEncoding = loaded.encoding
            editor = scratch
        }
        let engine = SearchEngine(editor: editor)
        switch kind {
        case .findAll:
            switch engine.findAll(text, options: options, path: url.path) {
            case .invalidRegex:
                stopped = .invalidRegex
            case .found(let fileHits) where !fileHits.isEmpty:
                let count = fileHits.reduce(0) { $0 + $1.ranges.count }
                resultFiles.append(SearchResultsFile(path: url.path, header: SearchResultsFormat.fileHeader(path: url.path, hits: count),
                                                     hits: fileHits))
                hits += count
            case .found:
                break
            }
        case .replace(let replacement):
            guard editor.send(SCI_GETREADONLY) == 0 else { return }
            if open == nil && !FileManager.default.isWritableFile(atPath: url.path) { return }  // read-only file
            switch engine.replaceAll(text, with: replacement, options: options) {
            case .invalidRegex:
                stopped = .invalidRegex
            case .readOnly:
                break
            case .done(let n, _) where n > 0:
                if let open {
                    open.save()
                } else if let encoding = loadedEncoding, !write(editor.utf8Bytes(), as: encoding, to: url) {
                    failed.append(url.path)
                    return
                }
                replaced += n
                hits += n
            case .done:
                break
            }
        }
    }

    /// Writes in the file's own encoding (BOM included), keeping its permissions.
    private func write(_ utf8: Data, as encoding: TextEncoding, to url: URL) -> Bool {
        do {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            try TextFile.encode(utf8, as: encoding).write(to: url, options: .atomic)
            if let permissions = attributes?[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            return true
        } catch {
            return false
        }
    }
}
