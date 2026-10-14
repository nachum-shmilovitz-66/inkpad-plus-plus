#!/usr/bin/env swift
// MAC-50: generates MacPad/Info.plist's document types from Notepad++'s langs.model.xml.
//
//   swift scripts/gen-file-types.swift            rewrite MacPad/Info.plist
//   swift scripts/gen-file-types.swift --check    exit 1 if MacPad/Info.plist is out of date
//
// Every language gets a document type (role Editor, rank Alternate: MacPad++ is offered in
// Open With but never takes a file type over by being installed — Notepad++'s installer does not
// either). An extension macOS already knows as a core text type (public.c-source, public.json …)
// uses that type; the others get a type MacPad++ imports per language, conforming to
// public.plain-text, so Finder can name them and Settings › File Association (MAC-51) can make
// MacPad++ their default app. The generic Text type stays as the fallback for everything else.

import Foundation
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let langsURL = root.appendingPathComponent("vendor/notepad-plus-plus/PowerEditor/src/langs.model.xml")
let tableURL = root.appendingPathComponent("MacPad/Sources/LanguageTable.swift")
let plistURL = root.appendingPathComponent("MacPad/Info.plist")
let check = CommandLine.arguments.contains("--check")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gen-file-types: \(message)\n".utf8))
    exit(1)
}

// Long names ("C source file") from the generated language table.
guard let table = try? String(contentsOf: tableURL, encoding: .utf8) else { fail("cannot read \(tableURL.path)") }
var longNames: [String: String] = [:]
let entry = try! NSRegularExpression(pattern: #"LanguageInfo\(name: "([^"]*)", shortName: "[^"]*", longName: "([^"]*)""#)
for m in entry.matches(in: table, range: NSRange(table.startIndex..., in: table)) {
    let name = String(table[Range(m.range(at: 1), in: table)!])
    if longNames[name] == nil { longNames[name] = String(table[Range(m.range(at: 2), in: table)!]) }
}

// Languages and their extensions, in file order; the first language to claim an extension keeps
// it, as LanguageCatalog does.
guard let doc = try? XMLDocument(contentsOf: langsURL, options: []),
      let nodes = try? doc.nodes(forXPath: "/NotepadPlus/Languages/Language") as? [XMLElement]
else { fail("cannot read \(langsURL.path)") }

/// A system type is used when it is one every Mac has (not an app's own) and it is text.
func systemType(for ext: String) -> String? {
    guard let type = UTType(filenameExtension: ext), type.isDeclared, !type.isDynamic,
          type.conforms(to: .text) else { return nil }
    let id = type.identifier
    let core = id.hasPrefix("public.") || id.hasPrefix("com.netscape.")
        || (id.hasPrefix("com.apple.") && !id.hasPrefix("com.apple.xcode.") && !id.hasPrefix("com.apple.dt."))
    return core ? id : nil
}

var claimed = Set<String>()
var documentTypes: [[String: Any]] = []
var imported: [[String: Any]] = []
for node in nodes {
    guard let name = node.attribute(forName: "name")?.stringValue, let longName = longNames[name] else { continue }
    let exts = (node.attribute(forName: "ext")?.stringValue ?? "")
        .split(separator: " ").map { $0.lowercased() }.filter { !$0.isEmpty && claimed.insert($0).inserted }
    guard !exts.isEmpty else { continue }
    var types: [String] = []
    var own: [String] = []
    for ext in exts {
        if let id = systemType(for: ext) {
            if !types.contains(id) { types.append(id) }
        } else {
            own.append(ext)
        }
    }
    if !own.isEmpty {
        let id = "app.macpad.lang." + name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        types.append(id)
        imported.append([
            "UTTypeIdentifier": id,
            "UTTypeDescription": longName,
            "UTTypeConformsTo": ["public.plain-text"],
            "UTTypeTagSpecification": ["public.filename-extension": own],
        ])
    }
    documentTypes.append([
        "CFBundleTypeName": longName,
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": types,
    ])
}
documentTypes.append([
    "CFBundleTypeName": "Text",
    "CFBundleTypeRole": "Editor",
    "LSHandlerRank": "Alternate",
    "LSItemContentTypes": ["public.text", "public.data"],
])

guard let data = try? Data(contentsOf: plistURL),
      var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
else { fail("cannot read \(plistURL.path)") }
plist["CFBundleDocumentTypes"] = documentTypes
plist["UTImportedTypeDeclarations"] = imported
let output = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

if check {
    guard output == data else { fail("MacPad/Info.plist is out of date; run swift scripts/gen-file-types.swift") }
    print("gen-file-types: up to date (\(documentTypes.count) document types, \(imported.count) imported types)")
} else {
    try output.write(to: plistURL)
    print("gen-file-types: wrote \(documentTypes.count) document types, \(imported.count) imported types, \(claimed.count) extensions")
}
