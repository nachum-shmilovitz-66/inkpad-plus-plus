#!/bin/zsh
# Fetches the read-only upstream source Inkpad++ builds from (gitignored): a shallow clone of the
# pinned tag into vendor/upstream. Safe to re-run; it leaves an existing checkout alone.
set -euo pipefail

TAG=v8.9.8.1
ROOT=${0:A:h:h}
DEST=${INKPAD_VENDOR_DIR:-$ROOT/vendor/upstream}  # the override is for tests only
# MAC-64: the tag is lightweight and upstream signs only its installers, so the source is pinned
# to the reviewed commit instead (scripts/deps/vendor.lock); anything else stops the build.
COMMIT=$(<"$ROOT/scripts/deps/vendor.lock")

verify() {
  local have=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo none)
  [[ $have == "$COMMIT" ]] || { echo "vendor: $DEST is at $have, expected $COMMIT ($TAG)" >&2; exit 1; }
  [[ -z $(git -C "$DEST" status --porcelain) ]] || { echo "vendor: $DEST has local changes" >&2; exit 1; }
}

if [[ -d $DEST/.git ]]; then
  verify
  echo "vendor present: $DEST ($TAG, $COMMIT)"
  exit 0
fi

mkdir -p "${DEST:h}"
git clone --depth 1 --branch "$TAG" https://github.com/notepad-plus-plus/notepad-plus-plus.git "$DEST"
verify
echo "vendor fetched: $DEST ($TAG, $COMMIT)"
