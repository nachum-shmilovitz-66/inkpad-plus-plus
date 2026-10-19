import AppKit

// `inkpad` (MAC-52): opens files in Inkpad++ from a shell, with upstream's command-line options.
// Installed as /usr/local/bin/inkpad → Inkpad++.app/Contents/MacOS/inkpad by the package.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("inkpad: \(message)\n".utf8))
    exit(code)
}

var options: CommandLineOptions
do {
    options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail(error.localizedDescription, code: 2)
}
if options.help {
    print(CommandLineOptions.usage)
    exit(0)
}

// Paths are the shell's: relative to its folder, and they must exist (Finder cannot open
// a file that is not there).
let cwd = FileManager.default.currentDirectoryPath
var missing = false
options.files = options.files.map { CommandLineOptions.absolutePath($0, cwd: cwd) }.filter { path in
    if FileManager.default.fileExists(atPath: path) { return true }
    FileHandle.standardError.write(Data("inkpad: no such file: \(path)\n".utf8))
    missing = true
    return false
}
if missing && options.files.isEmpty { exit(1) }

/// The app this tool lives in (through the /usr/local/bin symlink), else the installed one.
func inkpadApp() -> URL? {
    let tool = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app", Bundle(url: bundle)?.bundleIdentifier?.hasPrefix("app.inkpad.Inkpad") == true {
        return bundle
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.inkpad.Inkpad")
}

guard let app = inkpadApp() else { fail("Inkpad++ is not installed", code: 1) }

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
if options.noSession { configuration.arguments = ["-nosession"] }  // read at launch
if !options.files.isEmpty { configuration.appleEvent = options.openDocumentsEvent() }

var result: Error?
let done = DispatchSemaphore(value: 0)
if options.files.isEmpty {
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
        result = error
        done.signal()
    }
} else {
    NSWorkspace.shared.open(options.files.map { URL(fileURLWithPath: $0) }, withApplicationAt: app,
                            configuration: configuration) { _, error in
        result = error
        done.signal()
    }
}
done.wait()
if let result { fail(result.localizedDescription, code: 1) }
exit(missing ? 1 : 0)
