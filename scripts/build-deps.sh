#!/bin/zsh
# Builds the editor engine Inkpad++ links against, from the read-only upstream tree in vendor/:
#   build/deps/Scintilla.framework   (Scintilla's own Xcode project, Cocoa backend)
#   build/deps/liblexilla.a          (compiled here directly; see below)
#   build/deps/libscintilla-boostregex.a  (upstream's Boost regex engine, linked into Scintilla)
#
# Lexilla is not built from its Xcode project: that project hard-codes a signing team and does
# not list the three lexers upstream adds (LexObjC, LexSearchResult, LexUser), so it fails to
# link. Compiling lexers/*.cxx + lexlib/*.cxx + src/Lexilla.cxx picks them up without editing
# the vendor tree.
#
# Usage: scripts/build-deps.sh [--clean]      (macOS, Xcode command-line tools, arm64)
set -euo pipefail

ROOT=${0:A:h:h}
NPP=$ROOT/vendor/upstream
OUT=$ROOT/build/deps
OBJ=$ROOT/build/obj-lexilla
TARGET=arm64-apple-macos13.0

[[ ${1:-} == --clean ]] && rm -rf "$OUT" "$OBJ" "$ROOT/build/dd-scintilla" "$ROOT/build/obj-boostregex" "$ROOT/build/obj-uchardet"
mkdir -p "$OUT" "$OBJ" "$OBJ/shim"

# MAC-64: only the reviewed, unmodified upstream commit is built.
"$ROOT/scripts/fetch-vendor.sh" >/dev/null

# MAC-64: the vendor code parses every opened file — build it with the hardening Apple clang
# offers on top of its defaults (stack protector on every function with arrays, libc++'s bounds
# checks, zeroed locals).
HARDEN=(-fstack-protector-strong -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST -ftrivial-auto-var-init=zero)

echo "== libscintilla-boostregex.a"
# upstream's regex engine for Scintilla (MAC-29): boostregex/BoostRegExSearch.cxx with Boost.Regex
# in header-only standalone mode, plugged in through SCI_OWNREGEX — exactly how upstream builds
# it (boostregex/nppSpecifics.mak), so Regex searches use Boost's Perl syntax, not Scintilla's.
BRX=$ROOT/build/obj-boostregex
mkdir -p "$BRX"
brx_objs=()
for src in $NPP/boostregex/{BoostRegExSearch,UTF8DocumentIterator}.cxx $ROOT/scripts/deps/BoostRegexLocale.cxx; do
  name=${src:t:r}
  o=$BRX/$name.o
  brx_objs+=$o
  [[ -f $o && ! $src -nt $o ]] || xcrun clang++ -target $TARGET -std=c++17 -O2 -fPIC -DNDEBUG $HARDEN \
    -DSCI_OWNREGEX -DBOOST_REGEX_STANDALONE \
    -I"$NPP/scintilla/include" -I"$NPP/scintilla/src" -I"$NPP/boostregex" -c "$src" -o "$o"
done
rm -f "$OUT/libscintilla-boostregex.a"
xcrun libtool -static -o "$OUT/libscintilla-boostregex.a" $brx_objs
# BoostRegexLocale.o is referenced by nothing (it only runs a static initializer), hence -force_load
# below; without it macOS would classify every non-ASCII character as a non-letter.
cp "$NPP/scintilla/include/BoostRegexSearch.h" "$OUT/"   # upstream's extra SCFIND_REGEXP_* flags

echo "== Scintilla.framework"
xcodebuild -quiet \
  -project "$NPP/scintilla/cocoa/Scintilla/Scintilla.xcodeproj" -scheme Scintilla \
  -configuration Release -arch arm64 -derivedDataPath "$ROOT/build/dd-scintilla" \
  SYMROOT="$OUT" CONFIGURATION_BUILD_DIR="$OUT" MACOSX_DEPLOYMENT_TARGET=13.0 \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) SCI_OWNREGEX=1' \
  OTHER_CPLUSPLUSFLAGS="\$(inherited) ${HARDEN[*]}" \
  OTHER_LDFLAGS="-Wl,-force_load,$OUT/libscintilla-boostregex.a" \
  build
# Without SCI_OWNREGEX, Document.cxx defines its own CreateRegexSearch and the force-loaded Boost
# one would be a duplicate symbol, so the link succeeding plus Boost's class being present proves
# the switch took effect.
symbols=$(nm "$OUT/Scintilla.framework/Scintilla")
if [[ $symbols != *BoostRegexSearch* ]]; then
  echo "Scintilla.framework does not use upstream's Boost regex engine (SCI_OWNREGEX not applied)" >&2
  exit 1
fi

# upstream appended an unguarded C++ block (SearchResultMarkings, uses std::vector) to the public
# Scintilla.h. Swift's bridging header is compiled as plain Objective-C, so guard it — in the built
# framework's copy only; vendor/ stays pristine.
SCIH=$OUT/Scintilla.framework/Headers/Scintilla.h
if ! grep -q "Inkpad++: C++-only" "$SCIH"; then
  perl -0pi -e 's/(#include <vector>\r?\n.*?SearchResultMarkingLine \*_markings;\r?\n\};\r?\n)/\/* Inkpad++: C++-only *\/\n#ifdef __cplusplus\n$1#endif\n/s' "$SCIH"
  grep -q "Inkpad++: C++-only" "$SCIH" || { echo "failed to guard C++ block in $SCIH" >&2; exit 1; }
fi

echo "== liblexilla.a"
# LexUser.cxx includes <windows.h>; the only thing it needs from the MSVC world is _itoa.
cat > "$OBJ/shim/windows.h" <<'EOF'
#pragma once
static inline char *_itoa(int value, char *buf, int radix) {
	char tmp[33]; int i = 0; unsigned v = (radix == 10 && value < 0) ? -(unsigned)value : (unsigned)value;
	do { int d = v % radix; tmp[i++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= radix; } while (v);
	char *p = buf; if (radix == 10 && value < 0) *p++ = '-';
	while (i) *p++ = tmp[--i];
	*p = 0; return buf;
}
EOF
LEX=$NPP/lexilla
CXXFLAGS=(-target $TARGET -std=c++17 -O2 -fPIC -DNDEBUG $HARDEN
  -I"$LEX/include" -I"$LEX/lexlib" -I"$NPP/scintilla/include" -I"$OBJ/shim"
  -Wno-deprecated-declarations)

# MAC-65: lexers with bugs the MAC-25 fuzzing found (Raku stack overflow on a long word, Perl
# endless loop on a NUL in a here-doc, Perl here-doc delimiter overflow — all unfixed upstream)
# are compiled from patched copies; vendor/ stays pristine. scripts/deps/lexer-patches/<Lexer>-*.sh
# each patch one copy and fail unless their change applies exactly once.
PATCHED=$OBJ/patched
rm -rf "$PATCHED"; mkdir -p "$PATCHED"
patched_names=()
for patch in "$ROOT"/scripts/deps/lexer-patches/*.sh(N); do
  name=${${patch:t}%%-*}
  [[ -f $PATCHED/$name.cxx ]] || { cp "$LEX/lexers/$name.cxx" "$PATCHED/$name.cxx"; patched_names+=$name; }
  sh "$patch" "$PATCHED/$name.cxx"
done
srcs=()
for src in "$LEX"/lexers/*.cxx(N); do
  (( ${patched_names[(Ie)${src:t:r}]} )) || srcs+=$src
done
srcs+=("$PATCHED"/*.cxx(N) "$LEX"/lexlib/*.cxx(N) "$LEX/src/Lexilla.cxx")
objs=() stale=()
for src in $srcs; do
  o=$OBJ/${src:h:t}_${src:t:r}.o
  objs+=$o
  [[ ! -f $o || $src -nt $o ]] && stale+=("$src" "$o")
done
echo "${#objs} sources, $(( ${#stale} / 2 )) to compile"
if (( ${#stale} )); then
  # Flags travel in the environment (no spaces in them); xargs supplies "<src> <obj>" pairs.
  export LEXFLAGS="${CXXFLAGS[*]}"
  print -rN -- $stale | xargs -0 -n2 -P"$(sysctl -n hw.ncpu)" \
    sh -c 'xcrun clang++ $LEXFLAGS -c "$1" -o "$2"' _
fi
rm -f "$OUT/liblexilla.a"
xcrun libtool -static -o "$OUT/liblexilla.a" $objs
cp "$LEX/include/Lexilla.h" "$LEX/include/SciLexer.h" "$OUT/"

echo "== libuchardet.a"
# upstream's copy of Mozilla's universal charset detector (encoding detection, MAC-10).
UCD=$NPP/PowerEditor/src/uchardet
UOBJ=$ROOT/build/obj-uchardet
mkdir -p "$UOBJ"
uobjs=()
for src in "$UCD"/*.cpp(N); do
  o=$UOBJ/${src:t:r}.o
  uobjs+=$o
  [[ -f $o && ! $src -nt $o ]] || xcrun clang++ -target $TARGET -std=c++17 -O2 -fPIC -DNDEBUG $HARDEN -c "$src" -o "$o"
done
rm -f "$OUT/libuchardet.a"
xcrun libtool -static -o "$OUT/libuchardet.a" $uobjs
cp "$UCD/uchardet.h" "$OUT/"

echo "== done: $OUT"
ls -1 "$OUT"
