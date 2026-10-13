#!/bin/zsh
# Builds a Release MacPad++.app and packages it as build/MacPad++-<version>.dmg
# (drag-to-Applications layout).
#
# Signing: uses the first "Developer ID Application" identity in the keychain, with the hardened
# runtime; override with SIGN_IDENTITY="<name or hash>", or SIGN_IDENTITY=- for ad-hoc.
# Notarization (needed for other Macs to open it without a Gatekeeper warning) runs only when
# NOTARY_PROFILE names a profile stored with `xcrun notarytool store-credentials`.
#
# Usage: scripts/make-dmg.sh            (macOS, Xcode, XcodeGen)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
DD=$ROOT/build/dd-release
STAGE=$ROOT/build/dmg-stage

[[ -d build/deps/Scintilla.framework && -f build/deps/liblexilla.a ]] || scripts/build-deps.sh
xcodegen generate --quiet

echo "== Release build"
xcodebuild -quiet -project MacPad++.xcodeproj -scheme MacPad++ -configuration Release \
  -derivedDataPath "$DD" build
APP=$DD/Build/Products/Release/MacPad++.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
IDENTITY=${IDENTITY:--}
echo "== Signing with: $IDENTITY"
if [[ $IDENTITY == - ]]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi
# Inside-out: the embedded framework first, then the app.
$SIGN "$APP/Contents/Frameworks/Scintilla.framework"
$SIGN "$APP"
codesign --verify --deep --strict "$APP"

echo "== DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MacPad++.app"
ln -s /Applications "$STAGE/Applications"
DMG=$ROOT/build/MacPad++-$VERSION.dmg
rm -f "$DMG"
hdiutil create -quiet -volname "MacPad++ $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
[[ $IDENTITY == - ]] || codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE"

if [[ -n ${NOTARY_PROFILE:-} && $IDENTITY != - ]]; then
  echo "== Notarizing (profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "== done: $DMG"
