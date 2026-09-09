#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"
ODIN_ROOT="$(odin root)"

# §4: one C toolchain, and it cross-compiles. Unquoted on use, because it is two words.
CC=${CC:-zig cc}

# Odin's vendor bindings hard-code paths relative to the bindings package, so archives we
# build have to land inside the Odin install tree. That tree is often root-owned, so
# escalate for the copy only, and only when the destination really is not writable.
odin_install() {
    local src="$1" dst="$2" dir
    dir="$(dirname "$dst")"
    if [ -w "$dir" ] || { [ ! -e "$dir" ] && [ -w "$(dirname "$dir")" ]; }; then
        mkdir -p "$dir"
        cp "$src" "$dst"
    else
        echo "  $dst is not writable; using sudo to install it"
        sudo mkdir -p "$dir"
        sudo cp "$src" "$dst"
    fi
}

echo "==> libvterm (VT state machine for the terminal document; static lib)"
# leonerd's libvterm via the neovim mirror: a parser, no PTY and no I/O. We feed it bytes
# and read out a cell grid, owning the PTY and the painting ourselves. Dependency-free .c
# files, so cc + ar beats its libtool build; vendor/ is gitignored, so patches/ is re-applied
# on every fresh fetch.
VTERM_SRC="$VENDOR/libvterm"
VTERM_A="$VTERM_SRC/.libs/libvterm.a"
if [ -f "$VTERM_A" ]; then
    echo "  already present: libvterm.a"
else
    if [ ! -d "$VTERM_SRC" ] || [ -z "$(ls -A "$VTERM_SRC" 2>/dev/null)" ]; then
        echo "  cloning libvterm..."
        git clone --depth=1 "https://github.com/neovim/libvterm.git" "$VTERM_SRC"
    fi
    for p in "$VENDOR"/../patches/libvterm-*.patch; do
        [ -e "$p" ] || continue
        echo "  applying $(basename "$p")..."
        patch -p1 --forward -r - -d "$VTERM_SRC" < "$p" || true   # --forward: re-running is idempotent
    done
    echo "  building static libvterm.a..."
    (
        cd "$VTERM_SRC"
        mkdir -p .libs
        $CC -c -O2 -fPIC -Iinclude -Isrc src/*.c
        ar rcs .libs/libvterm.a ./*.o
        rm -f ./*.o
    )
    echo "  done."
fi

echo ""
echo "==> libgrapheme (cluster breaks, and §7's bidi later; static lib)"
# suckless's UAX #29/#9 library, the one cluster authority both sides of the seam read
# (IME.md §3). Plain C99 with no deps, so cc + ar beats its build, same as libvterm. Its
# generators run once from UCD data inside the tarball — no network — and they are HOST
# tools, so they stay on the system cc while the library objects take $CC like every other
# vendored archive. The line-break API fails conformance; nothing may call it.
LG_VERSION="3.0.0"
LG_SRC="$VENDOR/libgrapheme"
LG_A="$LG_SRC/libgrapheme.a"
if [ -f "$LG_A" ]; then
    echo "  already present: libgrapheme.a"
else
    if [ ! -d "$LG_SRC" ] || [ -z "$(ls -A "$LG_SRC" 2>/dev/null)" ]; then
        echo "  downloading libgrapheme $LG_VERSION source..."
        mkdir -p "$LG_SRC"
        # A failed download must not leave a partial tree a re-run would trust.
        curl -fsSL "https://dl.suckless.org/libgrapheme/libgrapheme-${LG_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C "$LG_SRC" \
            || { rm -rf "$LG_SRC"; exit 1; }
    fi
    echo "  building static libgrapheme.a..."
    (
        cd "$LG_SRC"
        for g in bidirectional case character line sentence word; do
            [ -f "gen/$g.h" ] && continue
            cc -O2 -o "gen/$g" "gen/$g.c" gen/util.c
            "./gen/$g" > "gen/$g.h"
        done
        $CC -c -O2 -fPIC -I. src/*.c
        ar rcs libgrapheme.a ./*.o
        rm -f ./*.o
    )
    echo "  done."
fi

echo ""
echo "==> sdl3 (the window, input and clipboard backend; static lib)"
# Stripped to video and events: everything else SDL offers, oket either does itself or does
# not do. X11, Wayland and libdecor are dlopened at run time, so only their headers matter
# here and the wayland protocol XMLs ride inside the tarball. OpenGL is not vendored:
# gl.load_up_to() takes it from the driver at runtime.
#
# Odin's bindings say `system:SDL3`, so every build passes
# -extra-linker-flags:"-L vendor/sdl3" and the only SDL3 that dir holds is this archive —
# the link is static even on a machine with a system libSDL3.so.
#
# Left on the system cc: cmake wants CMAKE_C_COMPILER to be one executable, and this is a
# link-time archive, not part of the LTO path $CC exists for.
SDL_VERSION="3.4.16"
SDL_SRC="$VENDOR/sdl3-src"
SDL_A="$VENDOR/sdl3/libSDL3.a"
if [ -f "$SDL_A" ]; then
    echo "  already present: libSDL3.a"
else
    if [ ! -d "$SDL_SRC" ] || [ -z "$(ls -A "$SDL_SRC" 2>/dev/null)" ]; then
        echo "  downloading sdl3 $SDL_VERSION source..."
        mkdir -p "$SDL_SRC"
        # A failed download must not leave a partial tree a re-run would trust.
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C "$SDL_SRC" \
            || { rm -rf "$SDL_SRC"; exit 1; }
    fi
    echo "  building static libSDL3.a..."
    cmake -S "$SDL_SRC" -B "$SDL_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DSDL_AUDIO=OFF -DSDL_GPU=OFF -DSDL_RENDER=OFF -DSDL_CAMERA=OFF \
        -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF \
        -DSDL_POWER=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_VULKAN=OFF \
        -DSDL_TEST_LIBRARY=OFF >/dev/null
    cmake --build "$SDL_SRC/build" --parallel >/dev/null
    mkdir -p "$(dirname "$SDL_A")"
    cp "$SDL_SRC/build/libSDL3.a" "$SDL_A"
    echo "  done."
fi

echo ""
echo "==> stb (rasterizes SYSTEM fonts into the atlas, decodes pictures; static libs)"
# No font is vendored: the bundled fallback is a committed bitmap atlas, and the real face is
# found on the system at startup.
#
# rect_pack comes along because `vendor:stb/truetype` imports it, and Odin checks every
# foreign lib at compile time even when we never call the packer.
#
# stb_image decodes pictures for a `render: cells` document. One file, and the formats it does
# not know are simply not shown.
#
# Odin ships the bindings but only prebuilt wasm/darwin objects. Odin's own build_stb.sh
# drops its .o files inside the Odin tree, which fails on a system-wide install, so we
# compile here and leave only the copy privileged. Each .c file is a shim around its header.
STB_SRC="${ODIN_ROOT%/}/vendor/stb/src"
STB_ODIN_LIB="${ODIN_ROOT%/}/vendor/stb/lib"
STB_OUT="$VENDOR/stb"                                       # project-local cache
for name in stb_truetype stb_rect_pack stb_image; do
    if [ -f "$STB_ODIN_LIB/$name.a" ]; then
        echo "  already present: $name.a"
        continue
    fi
    echo "  building $name.a..."
    mkdir -p "$STB_OUT"
    (
        cd "$STB_OUT"
        $CC -c -Os -fPIC "$STB_SRC/$name.c" -o "$name.o"
        ar rcs "$name.a" "$name.o"
        rm -f "$name.o"
    )
    echo "  installing into Odin tree: $STB_ODIN_LIB/$name.a"
    odin_install "$STB_OUT/$name.a" "$STB_ODIN_LIB/$name.a"
done

echo ""
echo "==> tree-sitter (the syntax plugin links the runtime; static lib)"
# The KERNEL links none of this. The syntax plugin does, which is why a parser can hang or
# fault without taking the session with it (§10). Dependency-free C with a lib.c amalgamation,
# so cc + ar beats its build system, same as libvterm. Per-language GRAMMARS are not vendored:
# one is fetched and built at runtime, which is what keeps a release small.
TS_VERSION="v0.26.9"
TS_SRC="$VENDOR/tree-sitter"
TS_A="$TS_SRC/libtree-sitter.a"
if [ -f "$TS_A" ]; then
    echo "  already present: libtree-sitter.a"
else
    if [ ! -d "$TS_SRC/lib" ]; then
        echo "  cloning tree-sitter $TS_VERSION..."
        rm -rf "$TS_SRC"
        git clone --depth=1 --branch "$TS_VERSION" \
            "https://github.com/tree-sitter/tree-sitter.git" "$TS_SRC"
    fi
    echo "  building static libtree-sitter.a..."
    (
        cd "$TS_SRC"
        $CC -c -O2 -fPIC -Ilib/include -Ilib/src lib/src/lib.c -o lib.o
        ar rcs libtree-sitter.a lib.o
        rm -f lib.o
    )
    echo "  done."
fi

echo ""
echo "==> tree-sitter-json (the ONE grammar that is vendored, and only for the gate)"
# A gate may not depend on the network, so the syntax test builds this one the same way the
# runtime installer builds any other. It is small — one parser.c, no external scanner — and it
# is not shipped: release.sh copies no grammars.
JSON_SRC="$VENDOR/tree-sitter-json"
if [ -f "$JSON_SRC/src/parser.c" ]; then
    echo "  already present: tree-sitter-json"
else
    echo "  cloning tree-sitter-json..."
    rm -rf "$JSON_SRC"
    git clone --depth=1 "https://github.com/tree-sitter/tree-sitter-json.git" "$JSON_SRC"
fi

echo ""
echo "All deps ready."
