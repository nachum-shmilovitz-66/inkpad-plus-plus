# MacPad++

A native macOS port of [Notepad++](https://notepad-plus-plus.org/) v8.9.8.1: Swift + AppKit UI over
the same Scintilla/Lexilla editing engine Notepad++ uses, reading Notepad++'s own language, styler
and theme files unchanged. Not affiliated with the Notepad++ project.

Status: milestone 1 of 7 (skeleton): open/save, syntax colouring by extension, Notepad++ default
theme, folding, encodings (UTF-8/BOM, UTF-16, ANSI) with byte-exact save. See `CLAUDE.md` for the
roadmap and known gaps.

## Build (macOS on Apple Silicon, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen))

```bash
scripts/fetch-vendor.sh   # shallow clone of Notepad++ v8.9.8.1 into vendor/
scripts/build-deps.sh     # Scintilla.framework + liblexilla.a into build/deps/
xcodegen                  # generates MacPad++.xcodeproj
open MacPad++.xcodeproj
```

Installer: `scripts/make-dmg.sh` → `dist/MacPad++-<version>.dmg` (signed with a Developer ID
certificate if one is in the keychain; set `NOTARY_PROFILE` to notarize).

## License

GPLv3, as a derivative of Notepad++ — see `LICENSE`. Scintilla and Lexilla are under their own
licence.
