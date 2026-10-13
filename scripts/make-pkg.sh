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
# Usage: scripts/make-pkg.sh             (macOS, Xcode, XcodeGen)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
DD=$ROOT/build/dd-release
STAGE=$ROOT/build/pkg-root
COMPONENT=$ROOT/build/MacPad++-component.pkg

[[ -d build/deps/Scintilla.framework && -f build/deps/liblexilla.a ]] || scripts/build-deps.sh
xcodegen generate --quiet

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
# Inside-out: the embedded framework first, then the app.
$SIGN "$APP/Contents/Frameworks/Scintilla.framework"
$SIGN "$APP"
codesign --verify --deep --strict "$APP"

echo "== PKG"
# pkgbuild takes a root directory, so the app is staged alone: everything under the root lands
# in /Applications, and nothing else must be in there.
rm -rf "$STAGE" "$COMPONENT"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MacPad++.app"

pkgbuild --quiet \
  --root "$STAGE" \
  --install-location /Applications \
  --identifier app.macpad.MacPad \
  --version "$VERSION" \
  "$COMPONENT"

mkdir -p "$ROOT/dist"
PKG=$ROOT/dist/MacPad++-$VERSION.pkg
rm -f "$PKG"

PKG_IDENTITY=${PKG_SIGN_IDENTITY:-$(security find-identity -v \
  | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}
PKG_IDENTITY=${PKG_IDENTITY:--}
if [[ $PKG_IDENTITY == - ]]; then
  echo "== No Developer ID Installer identity — building an unsigned package"
  productbuild --quiet --package "$COMPONENT" "$PKG"
else
  echo "== Signing installer with: $PKG_IDENTITY"
  productbuild --quiet --package "$COMPONENT" --sign "$PKG_IDENTITY" "$PKG"
fi
rm -rf "$STAGE" "$COMPONENT"

if [[ -n ${NOTARY_PROFILE:-} && $PKG_IDENTITY != - ]]; then
  echo "== Notarizing (profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "== done: $PKG"
