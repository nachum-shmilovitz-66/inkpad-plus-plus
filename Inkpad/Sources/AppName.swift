import Foundation

/// The app name the user sees: menu bar, Dock, Finder, the app's own menus and alerts (MAC-66).
/// It is the APP_DISPLAY_NAME build setting (Config/App.xcconfig) — Inkpad++, unless a gitignored
/// Config/Local.xcconfig overrides it for a personal build — which a build phase writes into
/// en.lproj/InfoPlist.strings. Info.plist itself keeps Inkpad++: Finder shows a localized name
/// only while the non-localized one matches the .app file name. Internal identifiers (bundle id,
/// helper, Application Support folder, defaults keys) never use it.
enum AppName {
    static let fallback = "Inkpad++"
    static let display = resolve(localized: Bundle.main.localizedInfoDictionary, info: Bundle.main.infoDictionary)

    /// CFBundleDisplayName, then CFBundleName, localized values first; an empty or unexpanded
    /// `$(…)` value is skipped.
    static func resolve(localized: [String: Any]?, info: [String: Any]?) -> String {
        for dictionary in [localized, info] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = (dictionary?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, !name.contains("$(") {
                    return name
                }
            }
        }
        return fallback
    }
}
