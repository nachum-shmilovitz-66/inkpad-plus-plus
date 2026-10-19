// Generated from upstream v8.9.8.1 Notepad_plus.rc (the compact "&Language" menu, letter
// submenus) by scripts/gen-language-menu.py. Values are langs.model.xml names.
// Do not edit by hand; regenerate instead. User Defined Language entries are left out.

enum LanguageMenuEntry {
    case item(title: String, language: String)
    case separator
    case submenu(title: String, items: [(title: String, language: String)])
}

let languageMenuEntries: [LanguageMenuEntry] = [
    .item(title: "None (Normal Text)", language: "normal"),
    .separator,
    .submenu(title: "A", items: [("ActionScript", "actionscript"), ("Ada", "ada"), ("ASN.1", "asn1"), ("ASP", "asp"), ("Assembly", "asm"), ("AutoIt", "autoit"), ("AviSynth", "avs")]),
    .submenu(title: "B", items: [("BaanC", "baanc"), ("Batch", "batch"), ("Blitzbasic", "blitzbasic")]),
    .submenu(title: "C", items: [("C", "c"), ("C#", "cs"), ("C++", "cpp"), ("Caml", "caml"), ("CMake", "cmake"), ("COBOL", "cobol"), ("CSound", "csound"), ("CoffeeScript", "coffeescript"), ("CSS", "css")]),
    .submenu(title: "D", items: [("D", "d"), ("Diff", "diff")]),
    .submenu(title: "E", items: [("Erlang", "erlang"), ("ErrorList", "errorlist"), ("Escape Sequence (ANSI)", "escseq"), ("ESCRIPT", "escript")]),
    .submenu(title: "F", items: [("Forth", "forth"), ("Fortran (free form)", "fortran"), ("Fortran (fixed form)", "fortran77"), ("Freebasic", "freebasic")]),
    .submenu(title: "G", items: [("GDScript", "gdscript"), ("Go", "go"), ("Gui4Cli", "gui4cli")]),
    .submenu(title: "H", items: [("Haskell", "haskell"), ("Hollywood", "hollywood"), ("HTML", "html")]),
    .submenu(title: "I", items: [("INI file", "ini"), ("Inno Setup", "inno"), ("Intel HEX", "ihex")]),
    .submenu(title: "J", items: [("Java", "java"), ("JavaScript", "javascript.js"), ("JSON", "json"), ("JSON5", "json5"), ("JSP", "jsp")]),
    .item(title: "KIXtart", language: "kix"),
    .submenu(title: "L", items: [("LaTeX", "latex"), ("LISP", "lisp"), ("Lua", "lua")]),
    .submenu(title: "M", items: [("Makefile", "makefile"), ("Matlab", "matlab"), ("Microsoft Transact-SQL", "mssql"), ("MMIXAL", "mmixal"), ("MS-DOS Style", "nfo")]),
    .submenu(title: "N", items: [("Nim", "nim"), ("Nncrontab", "nncrontab"), ("NSIS", "nsis")]),
    .submenu(title: "O", items: [("Objective-C", "objc"), ("OScript", "oscript")]),
    .submenu(title: "P", items: [("Pascal", "pascal"), ("Perl", "perl"), ("PHP", "php"), ("PostScript", "postscript"), ("PowerShell", "powershell"), ("Properties", "props"), ("Purebasic", "purebasic"), ("Python", "python")]),
    .submenu(title: "R", items: [("R", "r"), ("Raku", "raku"), ("REBOL", "rebol"), ("Registry", "registry"), ("Resource file", "rc"), ("Ruby", "ruby"), ("Rust", "rust")]),
    .submenu(title: "S", items: [("SAS", "sas"), ("Shell", "bash"), ("Scheme", "scheme"), ("Smalltalk", "smalltalk"), ("Spice", "spice"), ("SQL", "sql"), ("Swift", "swift"), ("S-Record", "srec")]),
    .submenu(title: "T", items: [("TCL", "tcl"), ("Tektronix extended HEX", "tehex"), ("TeX", "tex"), ("TOML", "toml"), ("txt2tags", "txt2tags"), ("TypeScript", "typescript")]),
    .submenu(title: "V", items: [("Visual Basic", "vb"), ("Visual Prolog", "visualprolog"), ("VHDL", "vhdl"), ("Verilog", "verilog")]),
    .item(title: "XML", language: "xml"),
    .item(title: "YAML", language: "yaml"),
]
