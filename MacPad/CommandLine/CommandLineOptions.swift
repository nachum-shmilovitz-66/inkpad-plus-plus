import Foundation

/// Notepad++'s command-line options (winmain.cpp), shared by the `macpad` tool and the app
/// (MAC-52). The tool parses them and hands them to MacPad++ inside the Open Documents Apple
/// event that LaunchServices sends with the files, so they work whether or not MacPad++ is running.
struct CommandLineOptions: Codable, Equatable {
    var files: [String] = []
    /// -n<line>: 1-based line for the caret.
    var line: Int?
    /// -c<column>: 1-based column, used with -n.
    var column: Int?
    /// -p<position>: 0-based position; wins over -n / -c.
    var position: Int?
    /// -l<language>: a langs.model.xml name ("python", "cpp" …), any case.
    var language: String?
    /// -ro: the files open read-only.
    var readOnly = false
    /// -nosession: launch without reopening the last session.
    var noSession = false
    /// -monitor: the files open in Monitoring (tail -f) mode.
    var monitor = false
    /// -r: a folder opens its files recursively.
    var recursive = false
    /// -openFoldersAsWorkspace: folders go to Folder as Workspace instead of being opened.
    var foldersAsWorkspace = false
    /// --help
    var help = false

    enum ParseError: LocalizedError, Equatable {
        case badNumber(String)
        case missingValue(String)
        case unknownOption(String)

        var errorDescription: String? {
            switch self {
            case .badNumber(let arg): "\(arg): not a number"
            case .missingValue(let arg): "\(arg): a value is missing"
            case .unknownOption(let arg): "unknown option \(arg) (see macpad --help)"
            }
        }
    }

    /// Options Notepad++ has that mean nothing on a Mac (window position, plugins, instances …):
    /// accepted and ignored, so command lines written for Notepad++ still work.
    static let ignoredFlags: Set<String> = [
        "-multiInst", "-noPlugin", "-notabbar", "-systemtray", "-loadingTime", "-alwaysOnTop",
        "-fullReadOnly", "-fullReadOnlySavingForbidden", "-notepadStyleCmdline", "-monitoringMode", "-quickPrint",
    ]
    static let ignoredPrefixes = ["-x", "-y", "-L", "-settingsDir=", "-titleAdd=", "-udl=", "-pluginMessage=",
                                  "-qn=", "-qt=", "-qf=", "-openSession", "-export="]

    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var endOfOptions = false
        func number(_ arg: String, _ prefix: String) throws -> Int {
            let value = arg.dropFirst(prefix.count)
            guard !value.isEmpty else { throw ParseError.missingValue(arg) }
            guard let n = Int(value), n >= 0 else { throw ParseError.badNumber(arg) }
            return n
        }
        for arg in arguments {
            if endOfOptions || !arg.hasPrefix("-") || arg == "-" {
                options.files.append(arg)
                continue
            }
            switch arg {
            case "--": endOfOptions = true
            case "--help", "-h", "-help": options.help = true
            case "-ro": options.readOnly = true
            case "-nosession": options.noSession = true
            case "-monitor": options.monitor = true
            case "-r": options.recursive = true
            case "-openFoldersAsWorkspace": options.foldersAsWorkspace = true
            case _ where ignoredFlags.contains(arg): break
            case _ where ignoredPrefixes.contains(where: { arg.hasPrefix($0) }): break  // before -p, -l: -pluginMessage=, -loadingTime
            case _ where arg.hasPrefix("-n"): options.line = try number(arg, "-n")
            case _ where arg.hasPrefix("-c"): options.column = try number(arg, "-c")
            case _ where arg.hasPrefix("-p"): options.position = try number(arg, "-p")
            case _ where arg.hasPrefix("-l"):
                let name = String(arg.dropFirst(2))
                guard !name.isEmpty else { throw ParseError.missingValue(arg) }
                options.language = name
            default: throw ParseError.unknownOption(arg)
            }
        }
        return options
    }

    /// Where the caret goes in a document, Notepad++'s way: -p wins; -c counts only with -n.
    enum Caret: Equatable {
        case position(Int)
        case line(Int, column: Int?)
    }

    var caret: Caret? {
        if let position { return .position(position) }
        if let line { return .line(max(line, 1), column: column.map { max($0, 1) }) }
        return nil
    }

    /// Anything beyond opening the files.
    var hasDocumentOptions: Bool {
        caret != nil || language != nil || readOnly || monitor || recursive || foldersAsWorkspace
    }

    static func absolutePath(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    static let usage = """
        Usage: macpad [options] [file …]

        Opens files in MacPad++ (launching it if needed), with Notepad++'s command-line options:
          -n<line>                  put the caret on this line
          -c<column>                … and this column (with -n)
          -p<position>              put the caret at this position (0-based; wins over -n/-c)
          -l<language>              open in this language (e.g. -lpython, -lcpp)
          -ro                       open read-only
          -monitor                  open in Monitoring (tail -f) mode
          -r                        open the files of a folder recursively
          -openFoldersAsWorkspace   open folders in Folder as Workspace
          -nosession                when launching, do not reopen the last session
          --                        everything after this is a file
          --help                    show this help
        Notepad++ options with no meaning on a Mac (-multiInst, -x, -y, -noPlugin …) are ignored.
        """

    // MARK: - Hand-off inside the Open Documents event

    /// The Apple event parameter that carries the options ('MPop').
    static let eventKeyword: AEKeyword = 0x4D50_6F70

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decoded(_ data: Data) -> CommandLineOptions? { try? JSONDecoder().decode(CommandLineOptions.self, from: data) }

    /// The Open Documents event for these files, with the options as an extra parameter.
    func openDocumentsEvent() -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (index, path) in files.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(descriptorType: typeData, data: encoded())!, forKeyword: Self.eventKeyword)
        return event
    }

    /// The options riding on an Open Documents event, if the `macpad` tool sent it.
    static func from(event: NSAppleEventDescriptor?) -> CommandLineOptions? {
        guard let data = event?.paramDescriptor(forKeyword: eventKeyword)?.data else { return nil }
        return decoded(data)
    }
}
