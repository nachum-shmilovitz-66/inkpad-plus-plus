#!/bin/zsh
# MAC-68: publishes an installer as GitHub release v<version> at HEAD, then deletes every other
# release, so GitHub keeps only the newest one (the user's rule, 2026-10-18 — like dist/ keeping
# only the newest .pkg). Older releases' git tags stay. deploy patch runs it after make-pkg.sh.
#   scripts/github-release.sh dist/MacPad++-1.0.0.pkg 1.0.0
# MAC-75: only a MacPad++ installer is published — the repository is public, "Notepad++" is Don Ho's
# trademark, and Check for Updates installs only MacPad++-<version>.pkg titled MacPad++. A personal
# build (MAC-66/67) is never released; make-pkg.sh builds the public package next to it.
# The release notes list the commits since the previous release; the app shows them in its offer.
set -euo pipefail
PKG=${1:?usage: github-release.sh <pkg> <version>}
VERSION=${2:?usage: github-release.sh <pkg> <version>}
[[ -f $PKG ]] || { echo "no such installer: $PKG" >&2; exit 1; }
TAG=v$VERSION
FILE=${PKG:t}
NAME=${FILE%-$VERSION.pkg}
[[ $NAME != $FILE ]] || { echo "$FILE is not <name>-$VERSION.pkg" >&2; exit 1; }

[[ $NAME == MacPad++ ]] || { echo "refusing to publish $FILE: only MacPad++-<version>.pkg is released" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/macpad-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
xar -x -f "$PKG" -C "$WORK" Distribution
grep -q '<title>MacPad++</title>' "$WORK/Distribution" \
  || { echo "refusing to publish $FILE: its installer is not titled MacPad++" >&2; exit 1; }
grep -q "<pkg-ref id=\"app.macpad.MacPad\" version=\"$VERSION\"" "$WORK/Distribution" \
  || { echo "refusing to publish $FILE: it is not version $VERSION" >&2; exit 1; }
pkgutil --check-signature "$PKG" | grep -q 'Developer ID Installer: .*(96Y4LX7FVB)' \
  || { echo "refusing to publish $FILE: not signed with the team's Developer ID Installer" >&2; exit 1; }

COMMIT=$(git rev-parse HEAD)
git merge-base --is-ancestor "$COMMIT" "origin/$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null \
  || { echo "HEAD $COMMIT is not pushed; push before releasing" >&2; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$PKG" --clobber
else
  # Notes: the commits since the previous release (its tag), without the release commits.
  PREVIOUS=$(gh release list --limit 1 --json tagName -q '.[0].tagName')
  NOTES=$WORK/notes.md
  [[ -z $PREVIOUS ]] || git fetch -q origin "refs/tags/$PREVIOUS:refs/tags/$PREVIOUS" 2>/dev/null || true
  print -r -- "$NAME $VERSION — installer for macOS (Apple Silicon)." > "$NOTES"
  if [[ -n $PREVIOUS ]] && git rev-parse -q --verify "refs/tags/$PREVIOUS" >/dev/null; then
    print -r -- "" >> "$NOTES"
    print -r -- "Changes since ${PREVIOUS#v}:" >> "$NOTES"
    git log --no-merges --format='- %s' "refs/tags/$PREVIOUS..$COMMIT" | grep -v '^- Release [0-9]' >> "$NOTES" || true
  fi
  print -r -- "" >> "$NOTES"
  print -r -- "Commit $COMMIT." >> "$NOTES"
  gh release create "$TAG" "$PKG" --target "$COMMIT" --title "$NAME $VERSION" --notes-file "$NOTES"
fi

for old in $(gh release list --limit 1000 --json tagName -q '.[].tagName'); do
  [[ $old == $TAG ]] || { gh release delete "$old" --yes; echo "== removed older release: $old"; }
done
echo "== released: $TAG ($FILE)"
