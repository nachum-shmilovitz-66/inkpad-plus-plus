import Foundation

// Notepad++'s File Status Auto-Detection (MAC-20): what to do when an open file is changed or
// deleted by another program. Pure, so the decisions and wording are unit-tested; EditorTab
// detects the change and MainWindowController asks.

/// What to ask the user about a file changed behind the editor's back.
enum ExternalChangePrompt: Equatable {
    /// "This file has been modified by another program. Do you want to reload it?"
    case reload(losesEdits: Bool)
    /// "… doesn't exist anymore. Keep this file in editor?"
    case keepDeleted

    /// Notepad++'s wording, adapted to an alert's title + body.
    func texts(path: String) -> (title: String, message: String, yes: String, no: String) {
        switch self {
        case .reload(let losesEdits):
            return ("\"\((path as NSString).lastPathComponent)\" was modified by another program",
                    losesEdits
                        ? "\(path)\n\nDo you want to reload it and lose the changes made in MacPad++?"
                        : "\(path)\n\nDo you want to reload it?",
                    "Reload", losesEdits ? "Keep My Changes" : "Don't Reload")
        case .keepDeleted:
            return ("\"\((path as NSString).lastPathComponent)\" doesn't exist anymore",
                    "\(path)\n\nKeep this file in the editor? It will be marked as unsaved, so saving writes it back.",
                    "Keep", "Close")
        }
    }
}

enum ExternalChangeAction: Equatable {
    case none
    /// Notepad++'s "Update silently": reload without asking (only when nothing would be lost).
    case reloadSilently
    case ask(ExternalChangePrompt)
}

enum ExternalChangePolicy {
    /// - Parameters:
    ///   - isModified: the buffer has unsaved edits (they would be lost by a reload).
    ///   - updateSilently: Notepad++'s preference; never applies when edits would be lost, nor to
    ///     a deleted file.
    static func action(for change: FileChange, isModified: Bool, updateSilently: Bool) -> ExternalChangeAction {
        switch change {
        case .unchanged:
            return .none
        case .appended, .replaced:
            if updateSilently && !isModified { return .reloadSilently }
            return .ask(.reload(losesEdits: isModified))
        case .missing:
            return .ask(.keepDeleted)
        }
    }
}

/// Preferences for File Status Auto-Detection, as Notepad++ names them. Stored now; the
/// Preferences window that edits them is milestone 4 (MAC-5).
enum FileStatusPreferences {
    static let enabledKey = "FileStatusAutoDetection"
    static let updateSilentlyKey = "FileStatusUpdateSilently"

    static var isEnabled: Bool {
        AppEnvironment.defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static var updateSilently: Bool {
        AppEnvironment.defaults.bool(forKey: updateSilentlyKey)
    }
}
