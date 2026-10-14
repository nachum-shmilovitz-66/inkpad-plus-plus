# MacPad++ security review — MAC-25 (2026-10-14)

Scope: MacPad++ 0.1.13 as installed, the source at the time of the review, the `.pkg` installer, and
the third-party code built from Notepad++ v8.9.8.1 (commit `dd40fe45`). Five reviews ran in parallel:
third-party provenance and advisories, the root-privileged paths, the app's handling of untrusted
input, packaging and code signing, and fuzzing of the native parsers every opened file goes through.
Every finding became a Bug ticket; every fix ships with a regression test.

## Summary

| # | Severity | Finding | Ticket | Status |
|---|----------|---------|--------|--------|
| 1 | High (Critical on multi-user Macs) | The root helper wrote any file for any signed client; the Touch ID check was in the app and proved only the *current* user — a standard user, or code running inside MacPad++, got root writes | MAC-55 | Fixed |
| 2 | High | The root LaunchDaemon ran the helper from inside `/Applications/MacPad++.app` (admin-writable parent, no launch constraint) | MAC-56 | Fixed |
| 3 | High | Lexilla Raku lexer: stack buffer overflow on any word of 99+ characters (crash on open) | MAC-65 | Fixed (patched copy) |
| 4 | Medium | Lexilla Perl lexer: endless loop on a 4-byte file (freeze on open) | MAC-65 | Fixed (patched copy) |
| 5 | Medium | Root write paths followed symlinks / used a guessable temp name; root read the user's swappable temp copy | MAC-57 | Fixed |
| 6 | Medium | Theme XML: external entities pulled local files into themes (and saving kept them); entity bombs hung every launch | MAC-60 | Fixed |
| 7 | Medium | Find/Replace in Files followed links out of the folder and replaced linked files with copies | MAC-61 | Fixed |
| 8 | Medium | Vendor source not pinned to a commit (tag is lightweight; Notepad++ signs only installers) | MAC-64 | Fixed |
| 9 | Low–Medium | Uninstall ran the script of any copy as root; root scripts honoured test overrides; link race | MAC-58 | Fixed |
| 10 | Low | Package relocatable; silent ad-hoc fallback; hardened runtime only at packaging time; no minimum OS | MAC-59 | Fixed |
| 11 | Low | Save replaced symlinks with 0755 copies and split hard links | MAC-62 | Fixed |
| 12 | Low | Crafted session crashed every launch; macros could send any selector; unbounded reads; paths in the log | MAC-63 | Fixed |
| 13 | Low | Vendor code built without available hardening flags; unported UDL lexer reachable | MAC-64 | Fixed |
| 14 | Info | Installer not notarized — Gatekeeper blocks a downloaded copy | MAC-54 | Open (needs the Apple ID login) |
| 15 | Info | uchardet: undefined-behaviour enum loads (no crash); lexers not used by MacPad++ with buffer overflows (TCMD, ASY, Metapost, Clarion, Magik, DMIS, ObjC config), Julia hang | — | Report upstream |

## The privileged helper (findings 1, 2, 5, 9)

**Before:** `MacPadHelper` (root, launchd) accepted any client signed by team 96Y4LX7FVB and wrote
whatever path it was given. Authorization was an `LAContext.deviceOwnerAuthentication` check in the
app — the current user's Touch ID, not an administrator's. A standard user could save `/etc/sudoers`
with their own finger; code running inside MacPad++ (e.g. a lexer exploit) could call the helper
directly and write `/Library/LaunchDaemons/x.plist` with no prompt at all. launchd ran the binary
from inside the app bundle, so replacing `/Applications/MacPad++.app` replaced what ran as root.

**After:**
- Each save carries an `AuthorizationExternalForm`; the **helper** asks Authorization Services for
  `app.macpad.MacPad.save` (group admin, not shared, never cached — installed by postinstall), with a
  prompt naming the resolved path. No right in the database: refused, never the cached default.
- Startup and security files (`/Library/Launch*`, `/Library/PrivilegedHelperTools`, `/System`,
  sudoers, pam.d, periodic, `/var/root`, `/var/db`) are refused on every route, through symlinks.
- Both code-signing requirements demand the Developer ID markers; protocol version 2 means older
  signed builds cannot use the new helper.
- The daemon runs a root-owned copy in `/Library/PrivilegedHelperTools` (0544) with a
  `SpawnConstraint` on team and identifier.
- Writes are descriptor-based (`openat` with `O_NOFOLLOW|O_EXCL`, `fchown`/`fchmod`, `renameat`, the
  folder checked with `F_GETPATH`); the password route runs the same code once as root and reads the
  user's copy only if it is still the user's own regular file.
- Uninstall runs only the root-owned `/Applications` copy's script; root scripts ignore test
  overrides.

## Untrusted input (findings 3, 4, 6, 7, 11, 12)

- **Lexers.** 142 lexers and uchardet were fuzzed under AddressSanitizer/UBSan (~12 M lexer runs,
  241 k uchardet runs). The two reachable bugs (Raku, Perl) are patched in copies compiled by
  `build-deps.sh` (vendor/ stays pristine); the rest are in lexers MacPad++ never selects.
- **XML.** Everything is loaded through `SafeXML`: no DTDs or entities (Notepad++ files have none),
  external entities off, 5 MB cap; a theme that does not load is never remembered.
- **Files.** Find in Files never leaves the folder searched; writes go through links to their files
  and keep hard links; files over 2 GB are refused (Notepad++'s own limit).
- **State.** Session values are clamped; macros play only recordable commands.

## Packaging and supply chain (findings 8, 10, 13, 14)

- `make-pkg.sh` refuses to build ad-hoc unless asked, verifies runtime + timestamp + team on every
  binary, builds a non-relocatable component with a minimum OS of 13.0 and no AppleDouble files, and
  `scripts/check-pkg.sh` checks every built package (BOM ownership and modes included).
- The vendor tree must be the pinned commit and clean (`scripts/deps/vendor.lock`); vendor code is
  built with `-fstack-protector-strong`, libc++ hardening and zero-initialised locals.
- **Open:** notarization (MAC-54) — the user's `notarytool` login failed; until then a downloaded
  installer is blocked by Gatekeeper on other Macs.

## Verified as sound

Package signature and timestamp; Distribution must-close / arm64 / no installer JavaScript; payload
root:wheel with nothing group- or world-writable; app, helper and framework hardened with no
entitlements (`get-task-allow` only in Debug); XPC requirements enforced by the system on both ends
(audit-token based); shell and AppleScript quoting; `/dev/zero` and FIFOs refused on open; theme
names cannot traverse paths; Style Configurator writes through the DOM; function-list parsers come
from the signed bundle only; Boost regex has a complexity limit; no URL schemes, AppleScript
dictionary or Services; the vendor tag resolves to the official repository's commit and the tree is
unmodified; every published Notepad++ CVE is either fixed in v8.9.8.1 or in Windows-only code that is
not compiled.

## Recommended follow-ups

1. Notarize once the Apple ID login works (MAC-54).
2. Report upstream: the Raku overflow and Perl hang (Lexilla), the uchardet enum UB, and the
   unused-lexer overflows (TCMD, ASY, Metapost, Clarion, Magik, DMIS, ObjC, Julia).
3. Re-run the fuzzing harness when Lexilla or Notepad++ is updated, before moving `vendor.lock`.
4. After installing 0.1.14, confirm an admin save shows the system's administrator prompt (Touch ID
   or password) — if MacPad++'s own password prompt appears instead, launchd refused the spawn
   constraint.
