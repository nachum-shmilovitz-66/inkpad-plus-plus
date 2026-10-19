#!/bin/sh
# Inkpad++ uninstaller (MAC-53). Runs as root; Inkpad++ › Uninstall Inkpad++… runs it through the
# administrator prompt, or from Terminal:
#   sudo sh "/Applications/Inkpad++.app/Contents/Resources/uninstall.sh"
# Removes what the package installed: the privileged helper's LaunchDaemon (stopped first), the
# /usr/local/bin/inkpad link (only if it is Inkpad++'s), the app, and the package receipt.
# Your own settings (~/Library/Application Support/Inkpad++) are not touched here.
# Argument: the app to remove (default /Applications/Inkpad++.app); it must be a Inkpad++.app.
# Test overrides (never set otherwise): INKPAD_LAUNCHD_DIR, INKPAD_LAUNCHCTL, INKPAD_BIN_DIR, INKPAD_PKGUTIL,
# INKPAD_SECURITY, INKPAD_HELPER_TOOLS_DIR.
set -u
# MAC-58: the test overrides below are honoured only when not running as root, so nothing in the
# environment can choose what root runs or touches.
if [ "$(/usr/bin/id -u)" = "0" ]; then
  unset INKPAD_LAUNCHD_DIR INKPAD_LAUNCHCTL INKPAD_BIN_DIR INKPAD_SECURITY INKPAD_HELPER_TOOLS_DIR INKPAD_PKGUTIL
fi

LABEL="app.inkpad.Inkpad.helper"
APP="${1:-/Applications/Inkpad++.app}"
DAEMONS="${INKPAD_LAUNCHD_DIR:-/Library/LaunchDaemons}"
LAUNCHCTL="${INKPAD_LAUNCHCTL:-/bin/launchctl}"
BIN="${INKPAD_BIN_DIR:-/usr/local/bin}"
PKGUTIL="${INKPAD_PKGUTIL:-/usr/sbin/pkgutil}"
SECURITY="${INKPAD_SECURITY:-/usr/bin/security}"
TOOLS="${INKPAD_HELPER_TOOLS_DIR:-/Library/PrivilegedHelperTools}"

case "$APP" in
  */Inkpad++.app) ;;
  *) echo "Inkpad++ uninstaller: $APP is not Inkpad++.app; nothing removed" >&2; exit 2 ;;
esac
if [ -d "$APP" ] && [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "Inkpad++ uninstaller: $APP does not look like an app; nothing removed" >&2
  exit 2
fi

"$LAUNCHCTL" bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/rm -f "$DAEMONS/$LABEL.plist" "$TOOLS/$LABEL"
"$SECURITY" authorizationdb remove app.inkpad.Inkpad.save >/dev/null 2>&1 || true

if [ -L "$BIN/inkpad" ] && /usr/bin/readlink "$BIN/inkpad" | /usr/bin/grep -q 'Inkpad++\.app/Contents/MacOS/inkpad$'; then
  /bin/rm -f "$BIN/inkpad"
fi

/bin/rm -rf "$APP"
"$PKGUTIL" --forget app.inkpad.Inkpad >/dev/null 2>&1 || true
echo "Inkpad++ uninstalled"
exit 0
