#!/usr/bin/env bash
# Builds one plugin source directory into <out>/<name>/<name>.so, the layout oket loads from. No
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
# ODIN is the collection ROOT, not the package: `plug` imports `../shape` beside it, so what
# `-collection:oket=` needs is the directory holding both. An Odin plugin then writes
# `import "oket:plug"` and builds the same in either layout.
#
# In the repo that root is all of src/, so `oket:txt` and `oket:store` also resolve there and
# NOT beside a release, which ships `plug` and `shape` and nothing else. Import those two.
if [ -d "$HERE/../src/helpers" ]; then
    ROOT="$(cd "$HERE/.." && pwd)"
    SEAM="$ROOT/src/plug"
    HELPERS="$ROOT/src/helpers"
    ODIN="$ROOT/src"
elif [ -d "$HERE/helpers" ]; then
    ROOT="$HERE"
    SEAM="$HERE/helpers"
    HELPERS="$HERE/helpers"
    ODIN="$HERE/helpers/odin"
else
    echo "stage.sh: cannot find the oket headers" >&2
    exit 1
fi

# A plugin that links something vendored says so in build.flags, one line of cc flags in its
# own directory, with $ROOT standing for the tree above this script — the alternative is
# stage.sh growing a case per plugin.
FLAGS=""
if [ -f "$SRC/build.flags" ]; then
    FLAGS="$(eval echo "$(cat "$SRC/build.flags")")"
fi

# THE SEAM IS A C ABI, NOT A C-ONLY ABI (§8). One language per plugin, found by what is in the
# directory, because a plugin is a directory and mixing two toolchains in one is a build system.
# A language stage.sh does not know builds itself, and its own recipe wins over anything found:
# the recipe rides in the plugin's folder like every other file it needs (§7), because
# release.sh and the test suite build it too and neither of them can pass a flag.
SRC_LANG=""
if [ -x "$SRC/build.sh" ]; then
    SRC_LANG="own"
else
    for ext in c cpp zig odin; do
        ls "$SRC"/*."$ext" >/dev/null 2>&1 || continue
        if [ -n "$SRC_LANG" ]; then
            echo "stage.sh: $SRC holds both .$SRC_LANG and .$ext; a plugin is one language" >&2
            exit 1
        fi
        SRC_LANG="$ext"
    done
fi
if [ -z "$SRC_LANG" ]; then
    echo "stage.sh: $SRC holds no plugin source (.c, .cpp, .zig, .odin) and no build.sh" >&2
    exit 1
fi

# -flto is the point of the C step. -fvisibility=hidden plus --gc-sections is what makes it
# pay: a plugin exports one symbol (OKET_MAIN), so everything the linker cannot reach from it
# goes, and nothing declares which helpers it wants.
#
# -g IS NOT A DEBUG BUILD (§5). It adds sections and changes no generated code, and without it a
# fault trace names every frame `browser.so(+0x1a4c)` and nothing resolves the offset. `zig cc`
# emits DWARF anyway; the flag is here for $CC, because a plain clang emits none and a trace that
# resolves is not a property to inherit from whichever compiler somebody points at us.
CFLAGS="-fPIC -O2 -g -flto -Wall -Wextra -I$SEAM -I$HELPERS -fvisibility=hidden"
CFLAGS="$CFLAGS -ffunction-sections -fdata-sections"
LDFLAGS="-flto -Wl,--gc-sections"
if [ "$ASAN" -eq 1 ]; then
    CFLAGS="$CFLAGS -fsanitize=address -fno-omit-frame-pointer -O1" # -g is already on
    LDFLAGS="$LDFLAGS -fsanitize=address"
fi

# The name segment is added here, not by the caller: every caller passes the plugins directory.
mkdir -p "$OUT/$NAME"
SO="$OUT/$NAME/$NAME.so"

# The C plugin compiles the helper SOURCES in and lets -flto inline them. Every other language
# drives its own linker and takes objects, so they get an archive instead. In a scratch
# directory, because the suite builds plugins in parallel and `.o` in $PWD is a collision.
WORK=""
HELPERS_A=""
trap 'if [ -n "$WORK" ]; then rm -rf "$WORK"; fi' EXIT INT TERM
# Sets HELPERS_A rather than echoing it: a `$(...)` would put the mktemp in a SUBSHELL, leaving
# the parent's WORK empty and the trap with nothing to remove.
helpers_archive() {
    WORK="$(mktemp -d)"
    ( cd "$WORK" && ${CC:-zig cc} -c -std=c11 -fPIC -O2 -I"$SEAM" -I"$HELPERS" "$HELPERS"/*.c )
    ar rcs "$WORK/liboket_helpers.a" "$WORK"/*.o
    HELPERS_A="$WORK/liboket_helpers.a"
}

# `zig cc` is two words, so $CC has to word-split as well as the flag lists do.
# shellcheck disable=SC2086
case "$SRC_LANG" in
c)
    ${CC:-zig cc} -shared -std=c11 $CFLAGS $LDFLAGS -o "$SO" \
        "$SRC"/*.c "$HELPERS"/*.c $FLAGS
    ;;
cpp)
    # The helpers stay C, and `-std=c++17` cannot be handed to a `.c` in the same command, so
    # they arrive as an archive.
    # A COLD zig cache prints a few hundred nullability warnings here. They are zig building
    # its own libc++, in compilations that never see our flags, and they do not come back.
    helpers_archive
    ${CXX:-zig c++} -shared -std=c++17 $CFLAGS $LDFLAGS -o "$SO" \
        "$SRC"/*.cpp "$HELPERS_A" $FLAGS
    ;;
zig)
    # ONE root file, named for the plugin, because `build-lib` takes a root and Zig reaches the
    # rest through `@import`. The helper sources go in beside it, so `@cImport("oket_helpers.h")`
    # resolves to definitions and not just declarations.
    [ -f "$SRC/$NAME.zig" ] || { echo "stage.sh: a zig plugin's root is $NAME.zig" >&2; exit 1; }
    zig build-lib -dynamic -fPIC -OReleaseFast -femit-bin="$SO" \
        -I"$SEAM" -I"$HELPERS" "$SRC/$NAME.zig" -lc "$HELPERS"/*.c $FLAGS
    ;;
odin)
    # Odin builds a DIRECTORY as one package, so there is no root file and no glob. `odin build`
    # drives the linker and takes no `.c`, so the helpers arrive as an archive.
    helpers_archive
    # -debug is odin's only door to DWARF, and it adds no checks: the same trade as -g above.
    odin build "$SRC" -build-mode:shared -out:"$SO" -collection:oket="$ODIN" -debug \
        -extra-linker-flags:"$HELPERS_A" $FLAGS
    ;;
own)
    # The contract, and all of it: source and output directories as the two arguments, the
    # header directories and the asan flag in the environment because only stage.sh knows which
    # layout it found, and $NAME.so in the output directory when it returns.
    OKET_ROOT="$ROOT" OKET_SEAM="$SEAM" OKET_HELPERS="$HELPERS" OKET_ODIN="$ODIN" \
        OKET_ASAN="$ASAN" \
        "$SRC/build.sh" "$SRC" "$OUT/$NAME"
    [ -f "$SO" ] || { echo "stage.sh: $SRC/build.sh left no $NAME.so" >&2; exit 1; }
    ;;
esac

# What is not source rides along: a plugin is a directory, so its grammar, its data table or
# its own fetch script lands in the folder the `.so` is in (§7).
#
# Not for `own`: a recipe stage.sh did not write can use any extension, so there is no way to
# tell its source from its data. It was handed the output directory and it places its own files.
if [ "$SRC_LANG" != "own" ]; then
    for f in "$SRC"/*; do
        case "$f" in
            *.c | *.h | *.cpp | *.hpp | *.zig | *.odin) continue ;;
            */build.flags | */build.sh) continue ;;
        esac
        rm -rf "${OUT:?}/$NAME/${f##*/}"
        cp -r "$f" "$OUT/$NAME/"
    done
fi
