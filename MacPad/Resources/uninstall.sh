#!/bin/sh
# MacPad++ uninstaller (MAC-53). Runs as root; MacPad++ › Uninstall MacPad++… runs it through the
# administrator prompt, or from Terminal:
#   sudo sh "/Applications/MacPad++.app/Contents/Resources/uninstall.sh"
# Removes what the package installed: the privileged helper's LaunchDaemon (stopped first), the
# /usr/local/bin/macpad link (only if it is MacPad++'s), the app, and the package receipt.
# Your own settings (~/Library/Application Support/MacPad++) are not touched here.
# Argument: the app to remove (default /Applications/MacPad++.app); it must be a MacPad++.app.
# Test overrides (never set otherwise): MACPAD_LAUNCHD_DIR, MACPAD_LAUNCHCTL, MACPAD_BIN_DIR, MACPAD_PKGUTIL.
set -u

LABEL="app.macpad.MacPad.helper"
APP="${1:-/Applications/MacPad++.app}"
DAEMONS="${MACPAD_LAUNCHD_DIR:-/Library/LaunchDaemons}"
LAUNCHCTL="${MACPAD_LAUNCHCTL:-/bin/launchctl}"
BIN="${MACPAD_BIN_DIR:-/usr/local/bin}"
PKGUTIL="${MACPAD_PKGUTIL:-/usr/sbin/pkgutil}"

case "$APP" in
  */MacPad++.app) ;;
  *) echo "MacPad++ uninstaller: $APP is not MacPad++.app; nothing removed" >&2; exit 2 ;;
esac
if [ -d "$APP" ] && [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "MacPad++ uninstaller: $APP does not look like an app; nothing removed" >&2
  exit 2
fi

"$LAUNCHCTL" bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/rm -f "$DAEMONS/$LABEL.plist"

if [ -L "$BIN/macpad" ] && /usr/bin/readlink "$BIN/macpad" | /usr/bin/grep -q 'MacPad++\.app/Contents/MacOS/macpad$'; then
  /bin/rm -f "$BIN/macpad"
fi

/bin/rm -rf "$APP"
"$PKGUTIL" --forget app.macpad.MacPad >/dev/null 2>&1 || true
echo "MacPad++ uninstalled"
exit 0
