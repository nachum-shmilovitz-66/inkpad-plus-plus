#!/bin/zsh
# MAC-68: publishes an installer as GitHub release v<version> at HEAD, then deletes every other
# release, so GitHub keeps only the newest one (the user's rule, 2026-10-18 — like dist/ keeping
# only the newest .pkg). Older releases' git tags stay. deploy patch runs it after make-pkg.sh.
#   scripts/github-release.sh dist/Notepad++-1.0.0.pkg 1.0.0
# A personal build named other than MacPad++ (MAC-66/67) goes only to a private repository:
# "Notepad++" is Don Ho's trademark.
set -euo pipefail
PKG=${1:?usage: github-release.sh <pkg> <version>}
VERSION=${2:?usage: github-release.sh <pkg> <version>}
[[ -f $PKG ]] || { echo "no such installer: $PKG" >&2; exit 1; }
TAG=v$VERSION
FILE=${PKG:t}
NAME=${FILE%-$VERSION.pkg}
[[ $NAME != $FILE ]] || { echo "$FILE is not <name>-$VERSION.pkg" >&2; exit 1; }

if [[ $NAME != MacPad++ && $(gh repo view --json isPrivate -q .isPrivate) != true ]]; then
  echo "refusing to publish the $NAME build to a public repository" >&2; exit 1
fi

COMMIT=$(git rev-parse HEAD)
git merge-base --is-ancestor "$COMMIT" "origin/$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null \
  || { echo "HEAD $COMMIT is not pushed; push before releasing" >&2; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$PKG" --clobber
else
  gh release create "$TAG" "$PKG" --target "$COMMIT" --title "$NAME $VERSION" \
    --notes "$NAME $VERSION — installer for macOS (Apple Silicon). Commit $COMMIT."
fi

for old in $(gh release list --limit 1000 --json tagName -q '.[].tagName'); do
  [[ $old == $TAG ]] || { gh release delete "$old" --yes; echo "== removed older release: $old"; }
done
echo "== released: $TAG ($FILE)"
