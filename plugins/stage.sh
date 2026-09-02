#!/usr/bin/env bash
# Builds one plugin source directory into <out>/<name>.so, the layout oket loads from. No
# manifest: a plugin registers itself by RUNNING, which is what dlopen is for (§7).
#
# release.sh, the gate test and `:pluginify` all call this, so the shape the tests exercise is
# the shape that ships and the shape you get while writing one.
#
# A LINK STEP, AND THE LINKER IS THE OPTIMISER: the helpers compile in with -flto, so a walk
# over a snapshot inlines into your loop and the half you never call is stripped
# (oket_helpers.h says why a shared library would not do).
set -euo pipefail

SRC="${1:?usage: stage.sh <plugin-src-dir> <out-dir> [--asan]}"
OUT="${2:?usage: stage.sh <plugin-src-dir> <out-dir> [--asan]}"
NAME="$(basename "$SRC")"
SRC="$(cd "$SRC" && pwd)"
shift 2 || true

# --asan catches a wild write AT THE WRITE with a stack trace, instead of at the crash four
# frames later inside kernel code (§10). It costs a shipped build nothing: you do not ship one.
ASAN=0
for arg in "$@"; do
    case "$arg" in
        --asan) ASAN=1 ;;
        *) echo "stage.sh: unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# Two layouts, one script, found rather than told, so `:pluginify` builds the same way in both
# places. In the repo the ABI header sits with its Odin twin under ../src/plug and the helper
# library under ../src/helpers; beside a shipped oket there is one include directory.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$HERE/../src/helpers" ]; then
    SEAM="$(cd "$HERE/../src/plug" && pwd)"
    HELPERS="$(cd "$HERE/../src/helpers" && pwd)"
elif [ -d "$HERE/helpers" ]; then
    SEAM="$HERE/helpers"
    HELPERS="$HERE/helpers"
else
    echo "stage.sh: cannot find the oket headers" >&2
    exit 1
fi

# A plugin that links something vendored says so in build.flags, one line of cc flags in its
# own directory — the alternative is stage.sh growing a case per plugin.
FLAGS=""
if [ -f "$SRC/build.flags" ]; then
    FLAGS="$(eval echo "$(cat "$SRC/build.flags")")"
fi

if ! ls "$SRC"/*.c >/dev/null 2>&1; then
    echo "stage.sh: $SRC holds no plugin source (.c)" >&2
    exit 1
fi

# -flto is the point of the whole step. -fvisibility=hidden plus --gc-sections is what makes it
# pay: a plugin exports one symbol (OKET_MAIN), so everything the linker cannot reach from it
# goes, and nothing declares which helpers it wants.
CFLAGS="-std=c11 -fPIC -O2 -flto -Wall -Wextra -I$SEAM -I$HELPERS -fvisibility=hidden"
CFLAGS="$CFLAGS -ffunction-sections -fdata-sections"
LDFLAGS="-flto -Wl,--gc-sections"
if [ "$ASAN" -eq 1 ]; then
    CFLAGS="$CFLAGS -fsanitize=address -fno-omit-frame-pointer -g -O1"
    LDFLAGS="$LDFLAGS -fsanitize=address"
fi

mkdir -p "$OUT"
# `zig cc` is two words, so $CC has to word-split as well as the flag lists do.
# shellcheck disable=SC2086
${CC:-zig cc} -shared $CFLAGS $LDFLAGS -o "$OUT/$NAME.so" \
    "$SRC"/*.c "$HELPERS"/oket_helpers.c $FLAGS
