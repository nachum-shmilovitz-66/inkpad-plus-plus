import Foundation

/// The documents that were open last time, so launching reopens them where they were left —
/// Notepad++'s session restore. Notepad++ also keeps unsaved "new N" buffers in a backup
/// directory; MacPad++ only restores documents that have a file on disk.
struct SessionState: Codable, Equatable {
    struct Document: Codable, Equatable {
        var path: String
        var caretPosition: Int
        var firstVisibleLine: Int
        /// Monitoring (tail -f) was on for this tab.
        var isMonitoring: Bool
        /// Bookmarked lines, 0-based (Notepad++'s <Mark line="N"/>).
        var bookmarks: [Int]
        /// The language chosen for the tab (Notepad++'s lang="…"); nil in older sessions.
        var language: String?

        init(path: String, caretPosition: Int = 0, firstVisibleLine: Int = 0, isMonitoring: Bool = false,
             bookmarks: [Int] = [], language: String? = nil) {
            self.path = path
            self.caretPosition = caretPosition
            self.firstVisibleLine = firstVisibleLine
            self.isMonitoring = isMonitoring
            self.bookmarks = bookmarks
            self.language = language
        }

        private enum CodingKeys: String, CodingKey { case path, caretPosition, firstVisibleLine, isMonitoring, bookmarks, language }

        /// Sessions written before monitoring or bookmarks existed lack those keys: read them as
        /// off / none, rather than discarding the whole session.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            caretPosition = try c.decode(Int.self, forKey: .caretPosition)
            firstVisibleLine = try c.decode(Int.self, forKey: .firstVisibleLine)
            isMonitoring = try c.decodeIfPresent(Bool.self, forKey: .isMonitoring) ?? false
            bookmarks = try c.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
            language = try c.decodeIfPresent(String.self, forKey: .language)
        }
    }

    /// Bumped when the stored shape changes; an unknown version is ignored rather than guessed at.
    static let currentVersion = 1

    var version: Int = SessionState.currentVersion
    /// The main view's documents (Notepad++'s <mainView>).
    var documents: [Document] = []
    var activeIndex: Int = 0
    /// The other view's (MAC-47, Notepad++'s <subView>). A document in both is a clone.
    var subDocuments: [Document] = []
    var subActiveIndex: Int = 0
    /// 0 = the main view had the focus, 1 = the other view.
    var activeView: Int = 0

    var isEmpty: Bool { documents.isEmpty && subDocuments.isEmpty }

    init(documents: [Document] = [], activeIndex: Int = 0,
         subDocuments: [Document] = [], subActiveIndex: Int = 0, activeView: Int = 0) {
        self.documents = documents
        self.activeIndex = activeIndex
        self.subDocuments = subDocuments
        self.subActiveIndex = subActiveIndex
        self.activeView = activeView
    }

    private enum CodingKeys: String, CodingKey { case version, documents, activeIndex, subDocuments, subActiveIndex, activeView }

    /// Sessions written before the split view have no other view: read it as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        documents = try c.decode([Document].self, forKey: .documents)
        activeIndex = try c.decode(Int.self, forKey: .activeIndex)
        subDocuments = try c.decodeIfPresent([Document].self, forKey: .subDocuments) ?? []
        subActiveIndex = try c.decodeIfPresent(Int.self, forKey: .subActiveIndex) ?? 0
        activeView = try c.decodeIfPresent(Int.self, forKey: .activeView) ?? 0
    }

    /// Returns nil for anything that is not a session this build understands, so a corrupt or
    /// future file costs the user their tabs, never their launch.
    static func decoded(from data: Data) -> SessionState? {
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data),
              state.version == currentVersion
        else { return nil }
        return state
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Drops documents whose file has gone away since the session was written, keeping the
    /// previously active document active when it survived, and otherwise landing as close to it
    /// as the remaining documents allow.
    func filtered(exists: (String) -> Bool) -> SessionState {
        let main = Self.filter(documents, active: activeIndex, exists: exists)
        let sub = Self.filter(subDocuments, active: subActiveIndex, exists: exists)
        let view = activeView == 1 && !sub.documents.isEmpty ? 1 : 0
        return SessionState(documents: main.documents, activeIndex: main.active,
                            subDocuments: sub.documents, subActiveIndex: sub.active, activeView: view)
    }

    private static func filter(_ documents: [Document], active: Int, exists: (String) -> Bool) -> (documents: [Document], active: Int) {
        let surviving = documents.enumerated().filter { exists($0.element.path) }
        guard !surviving.isEmpty else { return ([], 0) }
        if let kept = surviving.firstIndex(where: { $0.offset == active }) { return (surviving.map(\.element), kept) }
        let before = surviving.filter { $0.offset < active }.count
        return (surviving.map(\.element), min(before, surviving.count - 1))
    }
}

/// Where the session lives on disk. Reading and writing never throw at the caller: a session that
/// cannot be read is simply no session.
enum SessionStore {
    static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("session.json")
    }

    static func load(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionState.decoded(from: data)
    }

    @discardableResult
    static func save(_ state: SessionState, to url: URL = defaultURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try state.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("MacPad++: could not write the session file: \(error.localizedDescription)")
            return false
        }
    }
}
