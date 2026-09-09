#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$PROJECT_DIR/build"
# Lower case: what you type, the Wayland app-id, and the name release.yml ships.
BIN_NAME="oket"

usage() {
    cat <<EOF
usage: $(basename "$0") [--local [--asan] [--tarball]] [--public --version vX.Y.Z [--notes "text"]]

  --local               build locally into build/ inside the project (gitignored)
  --asan                with --local: build the kernel AND the plugins with AddressSanitizer
  --tarball             with --local: pack build/ into dist/ as the asset a release ships
  --public              trigger release.yml workflow via gh CLI
  --version <tag>       the tag; required with --public, and stamped into a --local build
  --notes <text>        optional release notes
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
DO_ASAN=0
DO_TARBALL=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --asan)    DO_ASAN=1; shift ;;
        --tarball) DO_TARBALL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --notes)   NOTES="${2:?--notes needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage
    exit 1
fi

if [ $DO_LOCAL -eq 1 ]; then
    echo "==> Local build: $BIN_NAME -> $RELEASE_DIR"
    # Empty the folder rather than replacing it: a recreated directory is a new inode, and
    # a shell sitting in the old one lands nowhere.
    mkdir -p "$RELEASE_DIR"
    find "$RELEASE_DIR" -mindepth 1 -delete
    # -L vendor/sdl3 satisfies the bindings' `system:SDL3` with the vendored libSDL3.a, so
    # the binary needs no system libSDL3. OKET_VERSION is quoted because -define parses its
    # value: a bare tag like 2.0 would arrive as a float.
    # §10's development build: a plugin's wild write is caught AT THE WRITE, with a stack
    # trace, instead of at the crash four frames later inside kernel code. It costs a shipped
    # build nothing, because you do not ship one. Not stripped and not optimised — the trace is
    # the whole point.
    if [ $DO_ASAN -eq 1 ]; then
        echo "==> AddressSanitizer build"
        odin build "$PROJECT_DIR/src/oket" -out:"$RELEASE_DIR/$BIN_NAME" \
            -sanitize:address -debug -extra-linker-flags:"-L$PROJECT_DIR/vendor/sdl3" \
            -define:OKET_VERSION='"dev-local-asan"'
    else
        odin build "$PROJECT_DIR/src/oket" -out:"$RELEASE_DIR/$BIN_NAME" \
            -o:speed -extra-linker-flags:"-L$PROJECT_DIR/vendor/sdl3" \
            -define:OKET_VERSION="\"${VERSION:-dev-local}\""
        # release.yml strips too, so a local build matches the download.
        strip --strip-all "$RELEASE_DIR/$BIN_NAME"
    fi
    # What the home page reads at every start (§13). Beside the binary, like config.conf: the
    # notes are what SHIPPED, so nothing at runtime has to have an opinion about them.
    if [ -f "$PROJECT_DIR/notes.md" ]; then
        cp "$PROJECT_DIR/notes.md" "$RELEASE_DIR/notes.md"
    fi
    # Themes are NOT shipped. The default is #load-ed into the binary (theme.odin) and the
    # folder is yours, like grammars: an install creates it empty and an uninstall leaves it.
    # The seam, shipped so `:pluginify` can build a plugin beside the binary; stage.sh finds
    # the headers in either layout.
    echo "==> Plugin toolchain"
    mkdir -p "$RELEASE_DIR/helpers"
    cp "$PROJECT_DIR"/src/plug/oket.h "$PROJECT_DIR"/src/helpers/*.h \
       "$PROJECT_DIR"/src/helpers/*.c "$RELEASE_DIR/helpers/"
    cp "$PROJECT_DIR/plugins/stage.sh" "$RELEASE_DIR/stage.sh"
    # tree-sitter itself is NOT shipped. plugins/syntax/get-tree-sitter fetches and builds it
    # into $ROOT/vendor, stage.sh carries that script into the plugin's folder, and nothing at
    # runtime opens the archive: the release ships the recipe.
    # Grammars are fetched and built on the machine that wants one (§11), and this is what
    # does it. Beside the binary, so a shell step reaches it by name.
    cp "$PROJECT_DIR/tools/oket-grammar" "$RELEASE_DIR/oket-grammar"
    PLUGIN_FLAGS=""
    [ $DO_ASAN -eq 1 ] && PLUGIN_FLAGS="--asan"
    for src in "$PROJECT_DIR"/plugins/*/; do
        [ -d "$src" ] || continue
        echo "==> Plugin: $(basename "$src")"
        # shellcheck disable=SC2086
        "$RELEASE_DIR/stage.sh" "$src" "$RELEASE_DIR/plugins" $PLUGIN_FLAGS
    done
    echo "==> Local done: $RELEASE_DIR"
fi

# The asset a release ships (INSTALL.md §8). ONE archive and not a file per plugin: what oket
# needs to run is a directory, and install.sh unpacks it and runs `oket --install`, which is the
# same code path `:oket install` runs from inside the app.
#
# The tarball holds what release.sh --local staged and nothing else. oket.desktop and the icon
# are #load-ed into the binary, so they are already in it.
if [ $DO_TARBALL -eq 1 ]; then
    if [ $DO_LOCAL -eq 0 ]; then
        echo "error: --tarball needs --local" >&2
        exit 1
    fi
    DIST_DIR="$PROJECT_DIR/dist"
    ARCH="$(uname -m)"
    TARBALL="$DIST_DIR/${BIN_NAME}-${ARCH}-linux.tar.gz"
    echo "==> Tarball: $TARBALL"
    mkdir -p "$DIST_DIR"
    rm -f "$DIST_DIR"/*.tar.gz
    # -C so the archive holds bare names and not build/. An unpack lands one directory, whatever
    # the person called it, and `oket --install` reads the folder beside the binary either way.
    tar -czf "$TARBALL" -C "$RELEASE_DIR" .
    cp "$PROJECT_DIR/install.sh" "$DIST_DIR/install.sh"
    echo "==> Tarball done: $(du -h "$TARBALL" | cut -f1)"
fi

if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2
        exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2
        exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for i in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"
            break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2
        exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
