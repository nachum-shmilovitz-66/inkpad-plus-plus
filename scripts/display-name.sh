#!/bin/zsh
# MAC-67: prints the visible name of a built app — the CFBundleDisplayName that the
# "Localized display name" build phase wrote from APP_DISPLAY_NAME (MAC-66) — or Inkpad++ when the
# app has none. make-pkg.sh names the installer and its title after it.
#   scripts/display-name.sh build/dd-release/Build/Products/Release/Inkpad++.app
set -u
setopt extended_glob  # the ## and # trimming patterns below
strings=${1:?usage: display-name.sh <app>}/Contents/Resources/en.lproj/InfoPlist.strings
name=$(/usr/libexec/PlistBuddy -c "Print CFBundleDisplayName" "$strings" 2>/dev/null) || name=
name=${name//[\/:]/-}            # usable in a file name
name=${name##[[:space:]]#}; name=${name%%[[:space:]]#}
[[ -n $name && $name != *'$('* ]] || name=Inkpad++
print -r -- "$name"
