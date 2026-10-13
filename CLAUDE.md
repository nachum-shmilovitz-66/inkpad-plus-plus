# MacPad++

A native macOS port of Notepad++ (v8.9.8.1). Goal: behave like the Windows Notepad++ the user
knows, but as a real Mac app — not Wine (tried, rejected as terrible), not a loose clone.

## Decisions (agreed with the user on 2026-10-13)

- **UI:** Swift + AppKit. Native menu bar, Cmd shortcuts, dark mode, Finder "Open With".
- **Editor engine:** Scintilla's Cocoa backend (`ScintillaView`) + Lexilla — the same engine
  Notepad++ uses, so editing/folding/multi-caret/column mode/lexers behave identically.
- **Data files reused verbatim from Notepad++:** `langs.model.xml`, `stylers.model.xml`,
  `themes/*.xml`, `functionList/*.xml`, `autoCompletion/*.xml`. Notepad++ user themes must import as-is.
- **Logic:** port non-Win32 C++ from `PowerEditor/src` where it is portable (encoding detection,
  search semantics, session/config formats). Rewrite every Win32 UI piece in AppKit.
- **Out of scope:** Notepad++ plugins (Windows DLLs cannot load on macOS).
- **License:** derived from Notepad++ ⇒ GPLv3. "Notepad++" is Don Ho's name — never brand the
  app with it; the app is **MacPad++**.

## Layout

- `vendor/notepad-plus-plus/` — shallow clone of tag `v8.9.8.1` (gitignored, read-only reference).
  - `scintilla/cocoa/` — ScintillaView, `Scintilla/Scintilla.xcodeproj`, `ScintillaTest/` (sample host app)
  - `lexilla/src/Lexilla/Lexilla.xcodeproj`
  - `PowerEditor/src/` — Notepad++ app code (`ScintillaComponent/`, `WinControls/`, `Parameters.cpp`, …)
  - `PowerEditor/src/langs.model.xml`, `stylers.model.xml`; `PowerEditor/installer/{themes,functionList,APIs}`
  - `boostregex/` — Notepad++'s regex engine for Scintilla search (Perl-style regex, used by Find/Replace)
- `scripts/build-deps.sh` — builds `build/deps/Scintilla.framework` + `liblexilla.a` from vendor/.
- `project.yml` — XcodeGen spec (the generated `MacPad++.xcodeproj` is gitignored).
- `MacPad/Sources/` — the app (Swift, AppKit, no nibs). `LanguageTable.swift` is generated from
  Notepad++'s `_langNameInfoArray`; regenerate it rather than editing by hand.
- At build time a script phase copies `langs.model.xml`, `stylers.model.xml` and `themes/` from
  vendor/ into the app's `Resources/npp/`.

## Build

```bash
scripts/build-deps.sh && xcodegen && xcodebuild -project MacPad++.xcodeproj -scheme MacPad++ -derivedDataPath build/dd-app build
```

App: `build/dd-app/Build/Products/Debug/MacPad++.app`.

Tests: `xcodebuild test -project MacPad++.xcodeproj -scheme MacPad++` (target `MacPad++Tests`; the
app's module is `MacPad`, since `MacPad++` is not a legal Swift module name).

Installer: `scripts/make-pkg.sh` → `dist/MacPad++-<version>.pkg` (tests, Release build, signing,
then `pkgbuild` + `productbuild`; installs into `/Applications`). A `.pkg` is the project's installer
format — not a `.dmg`. Note the two identity classes: a Developer ID *Application* certificate signs
the app, a Developer ID *Installer* certificate signs the package.

## Vendor quirks (handled without editing vendor/)

- Lexilla's Xcode project hard-codes signing team 4F446KW87E and omits the three lexers Notepad++
  adds (`LexObjC`, `LexSearchResult`, `LexUser`), so `build-deps.sh` compiles Lexilla directly.
- `LexUser.cxx` includes `<windows.h>` and calls MSVC `_itoa`: a generated shim header covers both.
- Notepad++ appended an unguarded C++ block (`SearchResultMarkings`, `std::vector`) to the public
  `Scintilla.h`. The Swift bridging header is plain ObjC, so `build-deps.sh` wraps it in
  `#ifdef __cplusplus` in the built framework's copy.
- Scintilla.h and other vendor files use CRLF line endings: patterns must allow `\r?\n`.

## Testing gotchas

- Never drive the app with `osascript ... keystroke` unless MacPad++ is verified frontmost: keys go
  to whatever app has focus (on 2026-10-13 a stray `x` + ⌘S reached the user's Chrome). Use
  `key code` (layout-independent; the user's input source is Hebrew, so `keystroke "x"` types ש)
  and check `frontmost` first. `pkill MacPad++` fails on the `+`; use `pkill -f 'MacPad\+\+\.app/Contents/MacOS'`.

## Milestones (each one ends with a working app)

1. **Skeleton** — Scintilla + Lexilla building for arm64; one window, open/save, lexer by file
   extension, Notepad++ default theme from `stylers.model.xml`.
2. **Tabs** — multi-document, session restore, recent files, encoding + EOL in status bar.
3. **Find/Replace** — Normal / Extended / Regex (boostregex), Find in Files, Mark, incremental search.
4. **Language menu, Style Configurator, themes, Preferences.**
5. **Edit commands** — line ops, case, comment toggle, Column Editor, macros, Shortcut Mapper.
6. **Panels** — Function List, Document Map, Folder as Workspace, split view.
7. **Packaging** — signed `.app`, `.pkg` installer, file-type associations.

Milestone 1: **done** (2026-10-13). One window per document; open/save (Finder "Open With" too);
lexer + keywords by extension from `langs.model.xml`; default theme from `stylers.model.xml`; folding,
brace match, Notepad++-style status bar; BOM/UTF-8/UTF-16/ANSI decode + byte-exact save; EOL kept.

Known approximations, to be closed in later milestones:
- Keyword-set mapping ports only the generic rule and the cpp family (`setCppLexer`); other
  per-language setup in `ScintillaEditView::defineDocType` (HTML-embedded scripts, etc.) is milestone 4.
- "ANSI" = Windows-1252; Notepad++ uses the system code page + uchardet (milestone 2). A Hebrew
  (Windows-1255) file opens as mojibake until then.
- Font sizes are scaled by 4/3 (Windows 96 dpi points → macOS points); new files use LF, not CRLF.
- No first-line language detection (`#!/bin/bash`, `<?xml`) yet.

Next: milestone 2 (Tabs).

## Environment

macOS 26.6 on Apple Silicon (arm64), Xcode 27.0, Swift 6.4. Progress file for this repo:
`~/.claude/progress/MacPad++.txt`.

## Process requirements (set by the user on 2026-10-13)

- **Jira:** every item of work gets a ticket in project **MAC** ("macpad++") on the private
  Atlassian site — board https://nachum-shmilovitz.atlassian.net/jira/software/projects/MAC/boards/167.
  Open the ticket before the work starts, close it with a description of what actually shipped.
- **Testing:** every feature ships with full unit-test coverage; every bug fix ships with a
  regression test. Extract logic out of AppKit views where needed so it can be tested headless.
- **Versioning:** the line starts at `0.1.0` (`MARKETING_VERSION` in `project.yml`). At this stage
  every release bumps the **patch** only.
- **`deploy patch`** means, in order: run the unit tests (a failure stops everything) → bump the
  patch → update and close the Jira tickets → commit and push → build the `.pkg` installer into `dist/`
  for every requested platform (currently macOS arm64 only; `.pkg`, never `.dmg`) → ask the user whether to install it.
