# MacPad++

A native macOS port of [Notepad++](https://notepad-plus-plus.org/) v8.9.8.1: Swift + AppKit UI over
the same Scintilla/Lexilla editing engine Notepad++ uses, reading Notepad++'s own language, styler
and theme files unchanged. Not affiliated with the Notepad++ project.

Current release: **1.1.2** (milestones 1–7 done; notarization pending). Each release's installer is
on the repository's GitHub Releases page (only the newest is kept).
See `CLAUDE.md` for the roadmap and known gaps.

## Features

### Editing engine and files
- Scintilla + Lexilla, the engine Notepad++ uses: folding, brace matching, multi-caret and column
  (rectangular) selection, word wrap, zoom, show all characters.
- Opens and saves UTF-8 (with or without BOM), UTF-16 LE/BE and ANSI / 46 legacy code pages
  byte-for-byte; encoding detection as Notepad++ does it (uchardet); line endings kept as found.
- Encoding and line-ending pickers in the status bar convert the document.
- Finder "Open With" and double-click; untitled "new N" documents.
- Save as Administrator for protected files (e.g. `/etc/hosts`): one Touch ID prompt through a
  privileged helper the installer sets up, with the password prompt as fallback.
- Reload prompt when a file changes on disk; deleted files stay open as unsaved.
- Monitoring (tail -f): a read-only tab that follows a growing file, including log rotation.

### Tabs and session
- One window, documents as tabs; the session (open files, caret, scroll, bookmarks, language) is
  restored at launch; Recent Files.
- Read-only in MacPad++ (per document or all) and the file's own Finder lock, shown with 🔒.

### Search
- Find / Replace / Mark panel: Normal, Extended (`\n \t \x41 …`) and Regular expression modes with
  Notepad++'s Boost regex engine (lookbehind, `\R`, atomic groups, named groups, Unicode `\w`);
  match case, whole word, wrap around, backward, in selection, ". matches newline"; history.
- Count, Replace, Replace All (one undo step), Find All in the current or all open documents,
  Replace All in all open documents.
- Search results panel: Notepad++'s layout and colours, newest search on top, double-click / F4
  to step through hits, copy lines or paths.
- Find in Files / Replace in Files: filters (`*.cpp *.h !*.log`, folder exclusions `!/tests`,
  `!+/log*`), sub-folders, hidden folders, progress with Cancel; files keep their encoding.
- Mark All, five token highlight styles with jump up/down, bookmarks (toggle, next/previous,
  cut/copy/paste/remove bookmarked lines).
- Incremental search bar (match count, highlight all) and Go To line or offset.

### Languages and appearance
- Language menu with Notepad++'s 93 languages; syntax colouring and per-language lexer setup as in
  Notepad++ (JavaScript, PHP and VBScript inside HTML, substyles, folding properties).
- Language from the extension, the file name (`Makefile`, `PKGBUILD` …) or the first line
  (`#!/bin/bash`, `<?xml` …).
- Themes: Notepad++'s 22 themes, and any Notepad++ theme file dropped into the themes folder.
- Style Configurator: colours, fonts, bold/italic/underline, user keywords and extensions, Global
  override — live preview, saved like Notepad++'s stylers.xml.
- Settings window: new document defaults, current line, caret, wrap, virtual space, fold marker
  style, line numbers, edge columns, padding, indentation per language, search options, and more.

### Edit commands
- Line Operations: duplicate, remove (consecutive) duplicate lines, split, join, move up/down,
  remove empty lines, insert blank line above/below, reverse, randomize, and sort — lexicographic,
  ignoring case, locale, integers, decimals (comma or dot), by length — ascending or descending,
  also by the columns of a column selection.
- Blank Operations: trim leading/trailing, EOL to space, tab ↔ space conversion.
- Convert case (UPPER, lower, Proper, Sentence and their "blend" forms, iNVERT, ranDOm), indent,
  line and block comment/uncomment with each language's comment tokens.
- Column Editor: insert text or number sequences (dec / hex / oct / bin, leading zeros or spaces)
  down a column.
- Copy the current file's path, name or folder, or all open files' names or paths.
- Begin/End Select (also in column mode).

### Macros and shortcuts
- Record, play back, save (with a shortcut) and run macros N times or until the end of the file —
  typing, editing commands, menu commands and Find / Replace operations, as Notepad++ records them;
  "Trim Trailing Space and Save" comes predefined.
- Shortcut Mapper: every menu command and macro with its shortcut, filter, modify / clear / reset,
  conflict warnings.

### Panels and views
- Function List: functions and classes of the current file from Notepad++'s parsers, sort A to Z,
  search box, double-click to jump; the caret's function stays selected.
- Document Map: the whole document zoomed out beside the editor; click, drag or scroll it to move.
- Folder as Workspace: folders as a tree; open files, Find in Files in a folder, copy paths, reveal
  in Finder, open in Terminal; remembered across launches.
- Split view: Move or Clone a document to the other view (a clone is the same document in a second
  editor), each view with its own tabs, synchronized vertical / horizontal scrolling; both views
  kept in the session.

### Toolbar
- Notepad++'s toolbar under the title bar: its buttons in its order and groups (New, Open, Save,
  Close | Cut, Copy, Paste | Undo, Redo | Find, Replace | Zoom | Sync scrolling | Word Wrap, Show All
  Characters | Document Map, Function List, Folder as Workspace | Monitoring | macro buttons).
- Buttons follow their commands: Save is grey until the document changes, toggles show pressed.
- Settings › Toolbar: SF Symbols (default) or Notepad++'s Fluent UI icons, regular or filled, in
  light and dark. View › Show/Hide Toolbar (⌥⌘T) and Customize Toolbar….

### Installing and the Mac side
- Signed `.pkg` installer (Developer ID); MacPad++ appears in Finder's Open With for every
  Notepad++ language's extensions (244 of them), never taking a file type over by itself.
- Settings › File Association: Notepad++'s categories — make MacPad++ the default app for chosen
  extensions, and give them back.
- `macpad` command-line tool (installed in `/usr/local/bin`) with Notepad++'s options:
  `macpad -n42 -c7 -lpython -ro file.py`, `-p<pos>`, `-monitor`, `-r`, `-openFoldersAsWorkspace`,
  `-nosession`; `macpad --help` lists them.
- Save as Administrator: the system's administrator prompt (Touch ID or password) names the file;
  system startup and security files are refused.
- MacPad++ › Uninstall MacPad++… removes the app, its helper, the `macpad` link and the receipt
  (optionally your settings). From Terminal:
  `sudo sh "/Applications/MacPad++.app/Contents/Resources/uninstall.sh"`.
- The name shown in the menu bar, Dock, Finder and installer can be changed for a personal build:
  `APP_DISPLAY_NAME` in a gitignored `Config/Local.xcconfig` (see `Config/App.xcconfig`).
- Security review (MAC-25, 2026-10-14): `docs/security/2026-10-14-MAC-25-security-review.md`.

### Coming next
- Notarization of the installer (MAC-54).
- Toolbar buttons still to come with their commands: Save All, Close All, Print, Show Indent Guide,
  Document List.
- Not ported yet: User Defined Languages, "Find in these search results…", printing, backups and
  auto-completion settings. Notepad++ plugins (Windows DLLs) cannot run on macOS.

### Keyboard shortcuts that differ from Notepad++
macOS reserves some of Notepad++'s keys, so these use Mac equivalents: Find Next / Previous ⌘G /
⇧⌘G (F3 / Shift+F3), Replace ⌥⌘F (Ctrl+H), Mark ⇧⌘M (Ctrl+M), Find in Files ⇧⌘F, Go To ⌘L
(Ctrl+G), Incremental Search ⌥⌘I, Toggle Comment ⌘/ (Ctrl+Q), Column Editor ⌥⌘C (Alt+C),
Move Line Up / Down ⌥⌘↑ / ⌥⌘↓, Record macro ⇧⌘R, Playback ⇧⌘P, Settings ⌘,. Any of them can be
changed in Settings › Shortcut Mapper. Bookmarks (F2), search results (F4) and the results
window (F7) keep Notepad++'s keys.

## Build (macOS on Apple Silicon, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen))

```bash
scripts/fetch-vendor.sh   # shallow clone of Notepad++ v8.9.8.1 into vendor/
scripts/build-deps.sh     # Scintilla.framework + liblexilla.a into build/deps/
xcodegen                  # generates MacPad++.xcodeproj
open MacPad++.xcodeproj
```

Installer: `scripts/make-pkg.sh` → `dist/MacPad++-<version>.pkg`, which installs `MacPad++.app`
into `/Applications`. It runs the unit tests first, then builds Release. The app is signed with a
Developer ID Application certificate and the package with a Developer ID Installer certificate when
those are in the keychain (override with `SIGN_IDENTITY` / `PKG_SIGN_IDENTITY`, or `-` for ad-hoc
and unsigned); set `NOTARY_PROFILE` to notarize.

## License

GPLv3, as a derivative of Notepad++ — see `LICENSE`. Scintilla and Lexilla are under their own
licence.
