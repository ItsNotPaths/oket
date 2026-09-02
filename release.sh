#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$PROJECT_DIR/build"
# Lower case: what you type, the Wayland app-id, and the name release.yml ships.
BIN_NAME="oket"

usage() {
    cat <<EOF
usage: $(basename "$0") [--local [--asan]] [--public --version vX.Y.Z [--notes "text"]]

  --local               build locally into build/ inside the project (gitignored)
  --asan                with --local: build the kernel AND the plugins with AddressSanitizer
  --public              trigger release.yml workflow via gh CLI
  --version <tag>       required when --public is used
  --notes <text>        optional release notes
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
DO_ASAN=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --asan)    DO_ASAN=1; shift ;;
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
    # GLFW_SHARED=false links vendor/glfw/lib/libglfw3.a, so the binary needs no system
    # libglfw. OKET_VERSION is quoted because -define parses its value: a bare tag like 2.0
    # would arrive as a float.
    # §10's development build: a plugin's wild write is caught AT THE WRITE, with a stack
    # trace, instead of at the crash four frames later inside kernel code. It costs a shipped
    # build nothing, because you do not ship one. Not stripped and not optimised — the trace is
    # the whole point.
    if [ $DO_ASAN -eq 1 ]; then
        echo "==> AddressSanitizer build"
        odin build "$PROJECT_DIR/src/oket" -out:"$RELEASE_DIR/$BIN_NAME" \
            -sanitize:address -debug -define:GLFW_SHARED=false \
            -define:OKET_VERSION='"dev-local-asan"'
    else
        odin build "$PROJECT_DIR/src/oket" -out:"$RELEASE_DIR/$BIN_NAME" \
            -o:speed -define:GLFW_SHARED=false -define:OKET_VERSION='"dev-local"'
        # release.yml strips too, so a local build matches the download.
        strip --strip-all "$RELEASE_DIR/$BIN_NAME"
    fi
    # Themes are data, beside the binary like config.conf. Grammars are NOT: one is fetched
    # and built on the machine that wants it.
    if [ -d "$PROJECT_DIR/themes" ]; then
        echo "==> Themes"
        mkdir -p "$RELEASE_DIR/themes"
        cp "$PROJECT_DIR"/themes/*.toml "$RELEASE_DIR/themes/"
    fi
    # The seam, shipped so `:pluginify` can build a plugin beside the binary; stage.sh finds
    # the headers in either layout.
    echo "==> Plugin toolchain"
    mkdir -p "$RELEASE_DIR/helpers"
    cp "$PROJECT_DIR"/src/plug/oket.h "$PROJECT_DIR"/src/helpers/*.h \
       "$PROJECT_DIR"/src/helpers/*.c "$RELEASE_DIR/helpers/"
    cp "$PROJECT_DIR/plugins/stage.sh" "$RELEASE_DIR/stage.sh"
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
