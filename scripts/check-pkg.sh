#!/bin/zsh
# MAC-59: checks a built Inkpad++ installer the way the MAC-25 review did; make-pkg.sh runs it on
# every package and fails the build if anything is off.
#   scripts/check-pkg.sh dist/Inkpad++-<version>.pkg
set -euo pipefail

PKG=${1:?usage: check-pkg.sh <pkg>}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/inkpad-check-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fail() { echo "check-pkg: $*" >&2; exit 1; }

pkgutil --expand-full "$PKG" "$WORK/x" >/dev/null
COMPONENT=$(print -l "$WORK"/x/*.pkg(N) | head -1)
[[ -n $COMPONENT ]] || fail "no component package inside"
INFO="$COMPONENT/PackageInfo"
DIST="$WORK/x/Distribution"

grep -q '<relocate>' "$INFO" && fail "the bundle is relocatable (BundleIsRelocatable must be false)"
grep -q 'install-location="/Applications"' "$INFO" || fail "install location is not /Applications"
grep -q '<app id="app.inkpad.Inkpad"' "$DIST" || fail "must-close is missing"
grep -q '<os-version min="13.0"' "$DIST" || fail "allowed-os-versions (13.0) is missing"
grep -q 'hostArchitectures="arm64"' "$DIST" || fail "hostArchitectures is not arm64"

PAYLOAD="$COMPONENT/Payload"
[[ -d $PAYLOAD/Inkpad++.app ]] || fail "no Inkpad++.app in the payload"
for f in Inkpad++ InkpadHelper inkpad; do
  [[ -x $PAYLOAD/Inkpad++.app/Contents/MacOS/$f ]] || fail "Contents/MacOS/$f missing"
done
[[ -f $PAYLOAD/Inkpad++.app/Contents/Resources/uninstall.sh ]] || fail "uninstall.sh missing"
[[ -z $(find "$PAYLOAD" -name '._*' -print -quit) ]] || fail "AppleDouble ._ files in the payload"
[[ ! -e $PAYLOAD/Inkpad++.app/Contents/Library/LaunchDaemons ]] || fail "stale Contents/Library/LaunchDaemons in the bundle"
grep -q 'authorizationdb write app.inkpad.Inkpad.save' "$COMPONENT/Scripts/postinstall" || fail "postinstall does not install the save right"
grep -q 'PrivilegedHelperTools' "$COMPONENT/Scripts/postinstall" || fail "postinstall does not copy the helper out of the bundle"

# Ownership in the bill of materials: everything root:wheel, nothing group/other-writable.
lsbom -p mugf "$COMPONENT/Bom" | while read -r mode uid gid name; do
  [[ $uid == 0 && $gid == 0 ]] || fail "$name is not root:wheel ($uid:$gid)"
  (( (8#$mode & 8#022) == 0 )) || fail "$name is group/other-writable ($mode)"
done

if pkgutil --check-signature "$PKG" | grep -q 'Developer ID Installer'; then
  echo "check-pkg: signed with Developer ID Installer"
else
  echo "check-pkg: warning: the package is not signed with Developer ID Installer" >&2
fi
echo "check-pkg: OK"
