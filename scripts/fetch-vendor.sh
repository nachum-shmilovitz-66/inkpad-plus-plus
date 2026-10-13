#!/bin/zsh
# Fetches the read-only Notepad++ source MacPad++ builds from (gitignored): a shallow clone of the
# pinned tag into vendor/notepad-plus-plus. Safe to re-run; it leaves an existing checkout alone.
set -euo pipefail

TAG=v8.9.8.1
ROOT=${0:A:h:h}
DEST=$ROOT/vendor/notepad-plus-plus

if [[ -d $DEST/.git ]]; then
  have=$(git -C "$DEST" describe --tags 2>/dev/null || echo unknown)
  [[ $have == "$TAG" ]] || echo "warning: $DEST is at $have, expected $TAG" >&2
  echo "vendor present: $DEST ($have)"
  exit 0
fi

mkdir -p "${DEST:h}"
git clone --depth 1 --branch "$TAG" https://github.com/notepad-plus-plus/notepad-plus-plus.git "$DEST"
