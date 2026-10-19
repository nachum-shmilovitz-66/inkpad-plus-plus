#!/bin/zsh
# Builds a Release Inkpad++.app and packages it as dist/Inkpad++-<version>.pkg, an installer
# that puts Inkpad++.app into /Applications.
#
# App signing: uses the first "Developer ID Application" identity in the keychain, with the
# hardened runtime; override with SIGN_IDENTITY="<name or hash>", or SIGN_IDENTITY=- for ad-hoc.
# Installer signing: uses the first "Developer ID Installer" identity (a different identity
# class — an Application identity cannot sign a .pkg); override with PKG_SIGN_IDENTITY, or set it
# to - to leave the package unsigned. Unsigned packages still install locally, with a Gatekeeper
# prompt.
# Notarization (needed for other Macs to open it without a warning) runs only when NOTARY_PROFILE
# names a profile stored with `xcrun notarytool store-credentials`, and only for a signed package.
#
# Running app: the package lists Inkpad++ as a "must-close" app, so if it is running when you
# click Install, macOS Installer asks whether to close it (or cancel) before touching
# /Applications. Only the Installer app honours this; `installer -pkg` on the command line does not.
#
# Usage: scripts/make-pkg.sh             (macOS, Xcode, XcodeGen)
#        DIST=<dir> scripts/make-pkg.sh  (write the package somewhere other than dist/)
#        PUBLIC_PKG=0 scripts/make-pkg.sh   (skip the public Inkpad++ package, see below)
# Older Inkpad++-*.pkg files in the output folder are deleted once the new one is built.
# The file and the installer title carry the app's visible name (MAC-67): <name>-<version>.pkg.
# MAC-75: when that name is not Inkpad++ (a personal build, Config/Local.xcconfig), a second,
# public package is built too — the same app with APP_DISPLAY_NAME=Inkpad++ — because only a
# Inkpad++ installer is ever published (scripts/github-release.sh) and offered by Check for Updates.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
STAGE=$ROOT/build/pkg-root
COMPONENT=$ROOT/build/Inkpad++-component.pkg

[[ -d build/deps/Scintilla.framework && -f build/deps/liblexilla.a ]] || scripts/build-deps.sh
xcodegen generate --quiet
swift scripts/gen-file-types.swift --check  # MAC-50: document types match langs.model.xml

echo "== Unit tests"
xcodebuild -quiet test -project Inkpad++.xcodeproj -scheme Inkpad++ \
  -derivedDataPath build/dd-test -destination 'platform=macOS,arch=arm64'

# Builds, signs and packages the app once: $1 overrides APP_DISPLAY_NAME (empty = the configured
# name), $2 is its derived-data folder. Sets NAME, VERSION and PKG, and adds PKG to BUILT.
build_package() {
  local override=$1 DD=$2
  echo "== Release build"
  rm -rf "$DD/Build/Products/Release/Inkpad++.app"  # no leftovers from older builds in the bundle (MAC-59)
  xcodebuild -quiet -project Inkpad++.xcodeproj -scheme Inkpad++ -configuration Release \
    -derivedDataPath "$DD" build ${override:+APP_DISPLAY_NAME=$override}
  APP=$DD/Build/Products/Release/Inkpad++.app
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  # MAC-67: the installer's title and file name follow the app's visible name (MAC-66) — Inkpad++
  # unless Config/Local.xcconfig overrides it. Identifiers and the payload path never change.
  NAME=$("$ROOT/scripts/display-name.sh" "$APP")

  IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
  IDENTITY=${IDENTITY:--}
  # MAC-59: an ad-hoc (unsigned) release only when asked for — never silently.
  if [[ $IDENTITY == - && ${ALLOW_ADHOC:-} != 1 ]]; then
    echo "No Developer ID Application identity; set ALLOW_ADHOC=1 to build an ad-hoc package" >&2; exit 1
  fi
  echo "== Signing app with: $IDENTITY"
  if [[ $IDENTITY == - ]]; then
    SIGN=(codesign --force --sign -)
  else
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
  fi
  # Inside-out: the privileged helper and the embedded framework first, then the app. The helper's
  # identifier is what the app's code-signing requirement for it names (MAC-24).
  $SIGN --identifier app.inkpad.Inkpad.helper "$APP/Contents/MacOS/InkpadHelper"
  $SIGN --identifier app.inkpad.Inkpad.cli "$APP/Contents/MacOS/inkpad"
  $SIGN "$APP/Contents/Frameworks/Scintilla.framework"
  $SIGN "$APP"
  codesign --verify --deep --strict "$APP"
  if [[ $IDENTITY != - ]]; then
    # MAC-59: every piece of code is hardened, timestamped and the team's.
    for code in "$APP/Contents/MacOS/InkpadHelper" "$APP/Contents/MacOS/inkpad" \
                "$APP/Contents/Frameworks/Scintilla.framework" "$APP"; do
      info=$(codesign -dvvv "$code" 2>&1)
      [[ $info == *"(runtime)"* && $info == *"Timestamp="* && $info == *"TeamIdentifier=96Y4LX7FVB"* ]] \
        || { echo "$code is not hardened, timestamped and team-signed:" >&2; echo "$info" >&2; exit 1; }
    done
  fi

  echo "== PKG"
  # pkgbuild takes a root directory, so the app is staged alone: everything under the root lands
  # in /Applications, and nothing else must be in there.
  rm -rf "$STAGE" "$COMPONENT"
  mkdir -p "$STAGE"
  ditto --noextattr --norsrc "$APP" "$STAGE/Inkpad++.app"  # no ._ AppleDouble files in the payload

  # scripts/pkg: preinstall stops a running helper, postinstall installs it as a launchd daemon
  # (MAC-28) — the Touch ID path for administrator saves, approved with the installation itself.
  # MAC-59: not relocatable — Installer must never "upgrade" a copy somewhere else (a build folder)
  # while postinstall wires /Applications/Inkpad++.app.
  COMPONENT_PLIST=$ROOT/build/Inkpad++-component.plist
  pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST" >/dev/null
  /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
  pkgbuild --quiet \
    --root "$STAGE" \
    --component-plist "$COMPONENT_PLIST" \
    --scripts "$ROOT/scripts/pkg" \
    --install-location /Applications \
    --identifier app.inkpad.Inkpad \
    --version "$VERSION" \
    "$COMPONENT"

  mkdir -p "$DIST"
  PKG=$DIST/$NAME-$VERSION.pkg
  BUILT+=("$PKG")
  rm -f "$PKG"

  # Distribution file: synthesized from the component, then Inkpad++ is declared must-close so
  # Installer asks to close a running copy first.
  DISTXML=$ROOT/build/Inkpad++-distribution.xml
  productbuild --quiet --synthesize --package "$COMPONENT" "$DISTXML"
  python3 -I - "$DISTXML" "$NAME" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
ref = next(r for r in root.findall("pkg-ref") if r.get("id") == "app.inkpad.Inkpad")
if ref.find("must-close") is None:
    close = ET.SubElement(ref, "must-close")
    ET.SubElement(close, "app", id="app.inkpad.Inkpad")
    # MAC-78 legacy: the old name's app, which postinstall removes, must not be running either.
    ET.SubElement(close, "app", id="app.macpad.MacPad")
# The app is built for Apple Silicon only; do not offer it to Intel Macs.
options = root.find("options")
if options is not None:
    options.set("hostArchitectures", "arm64")
# MAC-59: the same minimum macOS as the app (LSMinimumSystemVersion 13.0).
if root.find("allowed-os-versions") is None:
    allowed = ET.Element("allowed-os-versions")
    ET.SubElement(allowed, "os-version", min="13.0")
    root.insert(0, allowed)
title = root.find("title")
if title is None:
    title = ET.Element("title"); root.insert(0, title)
title.text = sys.argv[2]  # "Install <name>", "Welcome to the <name> Installer" (MAC-67)
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
  grep -q '<app id="app.inkpad.Inkpad"' "$DISTXML" || { echo "must-close missing from $DISTXML" >&2; exit 1; }

  PKG_IDENTITY=${PKG_SIGN_IDENTITY:-$(security find-identity -v \
    | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}
  PKG_IDENTITY=${PKG_IDENTITY:--}
  if [[ $PKG_IDENTITY == - && ${ALLOW_ADHOC:-} != 1 ]]; then
    echo "No Developer ID Installer identity; set ALLOW_ADHOC=1 to build an unsigned package" >&2; exit 1
  fi
  if [[ $PKG_IDENTITY == - ]]; then
    echo "== No Developer ID Installer identity — building an unsigned package"
    productbuild --quiet --distribution "$DISTXML" --package-path "${COMPONENT:h}" "$PKG"
  else
    echo "== Signing installer with: $PKG_IDENTITY"
    productbuild --quiet --distribution "$DISTXML" --package-path "${COMPONENT:h}" --sign "$PKG_IDENTITY" "$PKG"
  fi
  rm -rf "$STAGE" "$COMPONENT" "$DISTXML" "$COMPONENT_PLIST"
  "$ROOT/scripts/check-pkg.sh" "$PKG"  # MAC-59: the package as shipped, checked

  if [[ -n ${NOTARY_PROFILE:-} && $PKG_IDENTITY != - ]]; then
    echo "== Notarizing (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
  fi
}

DIST=${DIST:-$ROOT/dist}
BUILT=()
build_package "" "$ROOT/build/dd-release"
PERSONAL_NAME=$NAME
if [[ $NAME != Inkpad++ && ${PUBLIC_PKG:-1} != 0 ]]; then
  echo "== Public package: the same app named Inkpad++ (MAC-75)"
  build_package Inkpad++ "$ROOT/build/dd-release-public"
  [[ $NAME == Inkpad++ ]] || { echo "the public package is named $NAME, not Inkpad++" >&2; exit 1; }
fi

# Only the newest installer is kept (the user's rule, 2026-10-13): older versions are rebuilt from
# git when needed. Runs last, so a failed build never deletes the previous good package.
# Both names of this version stay (MAC-75: the personal and the public package).
olds=("$DIST"/Inkpad++-*.pkg(N) "$DIST"/$PERSONAL_NAME-*.pkg(N))  # either name (MAC-67)
for old in ${(u)olds}; do
  (( ${BUILT[(Ie)$old]} )) || { rm -f "$old"; echo "== removed older installer: ${old:t}"; }
done

# Xcode registers every app it builds with LaunchServices. The Release copies under build/ carry
# the installed app's bundle id, so Finder could launch one of them for the user's files instead of
# /Applications/Inkpad++.app (it did, 2026-10-14): unregister them.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$ROOT"/build/*/Inkpad++.app(N) "$ROOT"/build/*/Build/Products/*/Inkpad++.app(N); do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
done
# MAC-77: unregistering does not last — Launch Services finds apps on disk again (Spotlight,
# Finder), and the Release copies declare every document type, so "Inkpad++" came back to Open
# With beside the installed upstream. They are only intermediates, rebuilt on every run: delete
# them. (Debug copies declare no document types, MAC-74/76, and stay for the tests.)
for app in "$ROOT"/build/*/Inkpad++.app(N) "$ROOT"/build/*/Build/Products/Release/Inkpad++.app(N); do
  rm -rf "$app"
done

for built in $BUILT; do echo "== done: $built"; done
