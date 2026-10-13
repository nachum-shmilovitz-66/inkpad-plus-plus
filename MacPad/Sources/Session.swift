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

        init(path: String, caretPosition: Int = 0, firstVisibleLine: Int = 0, isMonitoring: Bool = false) {
            self.path = path
            self.caretPosition = caretPosition
            self.firstVisibleLine = firstVisibleLine
            self.isMonitoring = isMonitoring
        }

        private enum CodingKeys: String, CodingKey { case path, caretPosition, firstVisibleLine, isMonitoring }

        /// Sessions written before monitoring existed have no `isMonitoring`: read them as off,
        /// rather than discarding the whole session.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            caretPosition = try c.decode(Int.self, forKey: .caretPosition)
            firstVisibleLine = try c.decode(Int.self, forKey: .firstVisibleLine)
            isMonitoring = try c.decodeIfPresent(Bool.self, forKey: .isMonitoring) ?? false
        }
    }

    /// Bumped when the stored shape changes; an unknown version is ignored rather than guessed at.
    static let currentVersion = 1

    var version: Int = SessionState.currentVersion
    var documents: [Document] = []
    var activeIndex: Int = 0

    var isEmpty: Bool { documents.isEmpty }

    init(documents: [Document] = [], activeIndex: Int = 0) {
        self.documents = documents
        self.activeIndex = activeIndex
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
        let surviving = documents.enumerated().filter { exists($0.element.path) }
        guard !surviving.isEmpty else { return SessionState() }
        let newActive: Int
        if let kept = surviving.firstIndex(where: { $0.offset == activeIndex }) {
            newActive = kept
        } else {
            let before = surviving.filter { $0.offset < activeIndex }.count
            newActive = min(before, surviving.count - 1)
        }
        return SessionState(documents: surviving.map(\.element), activeIndex: newActive)
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
