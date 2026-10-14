#!/bin/zsh
# Builds a Release MacPad++.app and packages it as dist/MacPad++-<version>.pkg, an installer
# that puts MacPad++.app into /Applications.
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
# Running app: the package lists MacPad++ as a "must-close" app, so if it is running when you
# click Install, macOS Installer asks whether to close it (or cancel) before touching
# /Applications. Only the Installer app honours this; `installer -pkg` on the command line does not.
#
# Usage: scripts/make-pkg.sh             (macOS, Xcode, XcodeGen)
#        DIST=<dir> scripts/make-pkg.sh  (write the package somewhere other than dist/)
# Older MacPad++-*.pkg files in the output folder are deleted once the new one is built.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
DD=$ROOT/build/dd-release
STAGE=$ROOT/build/pkg-root
COMPONENT=$ROOT/build/MacPad++-component.pkg

[[ -d build/deps/Scintilla.framework && -f build/deps/liblexilla.a ]] || scripts/build-deps.sh
xcodegen generate --quiet
swift scripts/gen-file-types.swift --check  # MAC-50: document types match langs.model.xml

echo "== Unit tests"
xcodebuild -quiet test -project MacPad++.xcodeproj -scheme MacPad++ \
  -derivedDataPath build/dd-test -destination 'platform=macOS,arch=arm64'

echo "== Release build"
xcodebuild -quiet -project MacPad++.xcodeproj -scheme MacPad++ -configuration Release \
  -derivedDataPath "$DD" build
APP=$DD/Build/Products/Release/MacPad++.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
IDENTITY=${IDENTITY:--}
echo "== Signing app with: $IDENTITY"
if [[ $IDENTITY == - ]]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi
# Inside-out: the privileged helper and the embedded framework first, then the app. The helper's
# identifier is what the app's code-signing requirement for it names (MAC-24).
$SIGN --identifier app.macpad.MacPad.helper "$APP/Contents/MacOS/MacPadHelper"
$SIGN "$APP/Contents/Frameworks/Scintilla.framework"
$SIGN "$APP"
codesign --verify --deep --strict "$APP"

echo "== PKG"
# pkgbuild takes a root directory, so the app is staged alone: everything under the root lands
# in /Applications, and nothing else must be in there.
rm -rf "$STAGE" "$COMPONENT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MacPad++.app"

# scripts/pkg: preinstall stops a running helper, postinstall installs it as a launchd daemon
# (MAC-28) — the Touch ID path for administrator saves, approved with the installation itself.
pkgbuild --quiet \
  --root "$STAGE" \
  --scripts "$ROOT/scripts/pkg" \
  --install-location /Applications \
  --identifier app.macpad.MacPad \
  --version "$VERSION" \
  "$COMPONENT"

DIST=${DIST:-$ROOT/dist}
mkdir -p "$DIST"
PKG=$DIST/MacPad++-$VERSION.pkg
rm -f "$PKG"

# Distribution file: synthesized from the component, then MacPad++ is declared must-close so
# Installer asks to close a running copy first.
DISTXML=$ROOT/build/MacPad++-distribution.xml
productbuild --quiet --synthesize --package "$COMPONENT" "$DISTXML"
python3 -I - "$DISTXML" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
ref = next(r for r in root.findall("pkg-ref") if r.get("id") == "app.macpad.MacPad")
if ref.find("must-close") is None:
    ET.SubElement(ET.SubElement(ref, "must-close"), "app", id="app.macpad.MacPad")
# The app is built for Apple Silicon only; do not offer it to Intel Macs.
options = root.find("options")
if options is not None:
    options.set("hostArchitectures", "arm64")
if root.find("title") is None:
    title = ET.Element("title"); title.text = "MacPad++"; root.insert(0, title)
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
grep -q '<app id="app.macpad.MacPad"' "$DISTXML" || { echo "must-close missing from $DISTXML" >&2; exit 1; }

PKG_IDENTITY=${PKG_SIGN_IDENTITY:-$(security find-identity -v \
  | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}
PKG_IDENTITY=${PKG_IDENTITY:--}
if [[ $PKG_IDENTITY == - ]]; then
  echo "== No Developer ID Installer identity — building an unsigned package"
  productbuild --quiet --distribution "$DISTXML" --package-path "${COMPONENT:h}" "$PKG"
else
  echo "== Signing installer with: $PKG_IDENTITY"
  productbuild --quiet --distribution "$DISTXML" --package-path "${COMPONENT:h}" --sign "$PKG_IDENTITY" "$PKG"
fi
rm -rf "$STAGE" "$COMPONENT" "$DISTXML"

if [[ -n ${NOTARY_PROFILE:-} && $PKG_IDENTITY != - ]]; then
  echo "== Notarizing (profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

# Only the newest installer is kept (the user's rule, 2026-10-13): older versions are rebuilt from
# git when needed. Runs last, so a failed build never deletes the previous good package.
for old in "$DIST"/MacPad++-*.pkg(N); do
  [[ $old == "$PKG" ]] || { rm -f "$old"; echo "== removed older installer: ${old:t}"; }
done

# Xcode registers every app it builds with LaunchServices. The Release copies under build/ carry
# the installed app's bundle id, so Finder could launch one of them for the user's files instead of
# /Applications/MacPad++.app (it did, 2026-10-14): unregister them.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$ROOT"/build/*/MacPad++.app(N) "$ROOT"/build/*/Build/Products/*/MacPad++.app(N); do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
done

echo "== done: $PKG"
