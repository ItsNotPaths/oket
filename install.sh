#!/usr/bin/env sh
#
# oket installer.
#
#   curl -fsSL https://github.com/ItsNotPaths/oket/releases/latest/download/install.sh | sh
#
# What it does, and NOTHING else:
#
#   1. downloads the release tarball and unpacks it to a temporary folder
#   2. runs `oket --install` out of that folder
#   3. deletes the folder
#
# Step 2 is where everything actually happens, and it is the same code `:oket install` runs from
# inside the app (src/oket/install.odin): the binary to ~/.local/bin, the plugins and the tools
# to $XDG_DATA_HOME/oket, config.conf to $XDG_CONFIG_HOME/oket, and a launcher entry. That split
# is deliberate. A shell script cannot know what a release ships without being edited every time
# one changes; the program it is installing already does.
#
# POSIX sh, not bash: this is run by whatever `sh` is, on a machine that has just met us.
#
# Flags:
#   --version <tag>  install that release instead of the latest
#   --keep           leave the unpacked folder behind, and say where it is

set -eu

REPO="ItsNotPaths/oket"
BIN_NAME="oket"
BIN_DIR="${HOME}/.local/bin"
REL_TAG="latest"
KEEP=0

usage() {
    cat <<'EOF'
usage: install.sh [--version <tag>] [--keep]

Downloads the oket release, unpacks it, and runs `oket --install` out of it.

  --version <tag>  install that release instead of the latest
  --keep           leave the unpacked folder behind, and say where it is
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) REL_TAG="${2:?--version needs a value}"; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- what machine is this ---

# /etc/os-release's ID, and the family behind it. The family is used for ONE thing: naming the
# command that installs a missing curl, because "install curl" is a different sentence on every
# distribution. Nothing here installs a package on your behalf.
#
# The file is PARSED, not sourced. Sourcing it is the usual trick and it is wrong here: the file
# sets VERSION, NAME and a dozen other common words, and it would quietly overwrite whatever this
# script happens to call the same thing.
os_release_field() {
    [ -r /etc/os-release ] || return 0
    sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d '"'"'"
}

OS_ID="$(os_release_field ID)"
OS_LIKE="$(os_release_field ID_LIKE)"
[ -n "$OS_ID" ] || OS_ID="unknown"

os_family() {
    case " ${OS_ID} ${OS_LIKE} " in
        *" arch "*|*" archlinux "*|*" omarchy "*) echo arch ;;
        *" debian "*|*" ubuntu "*)                echo debian ;;
        *" fedora "*|*" rhel "*|*" centos "*)     echo fedora ;;
        *" suse "*|*" opensuse "*)                echo suse ;;
        *" alpine "*)                             echo alpine ;;
        *)                                        echo unknown ;;
    esac
}

pkg_hint() {
    case "$(os_family)" in
        arch)   echo "sudo pacman -S $1" ;;
        debian) echo "sudo apt install $1" ;;
        fedora) echo "sudo dnf install $1" ;;
        suse)   echo "sudo zypper install $1" ;;
        alpine) echo "sudo apk add $1" ;;
        *)      echo "install $1 with your package manager" ;;
    esac
}

ARCH="$(uname -m)"
[ "$(uname -s)" = "Linux" ] || die "oket is Linux only (this is $(uname -s))."
# The PTY layer is POSIX and one build is published. Saying so beats downloading it and watching
# the kernel refuse to run it.
[ "$ARCH" = "x86_64" ] || die "no ${ARCH} build is published — build from source: https://github.com/${REPO}"

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "neither curl nor wget is installed. $(pkg_hint curl)"
fi

command -v tar >/dev/null 2>&1 || die "tar is not installed. $(pkg_hint tar)"

# --- 1. the tarball ---

ASSET="${BIN_NAME}-${ARCH}-linux.tar.gz"
if [ "$REL_TAG" = "latest" ]; then
    URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
    URL="https://github.com/${REPO}/releases/download/${REL_TAG}/${ASSET}"
fi

say "oket  ·  ${OS_ID} ($(os_family)), ${ARCH}"
step "Downloading ${ASSET} (${REL_TAG})"

WORK="$(mktemp -d)"
[ "$KEEP" -eq 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

fetch "$URL" "$WORK/$ASSET" || die "download failed: $URL"
[ -s "$WORK/$ASSET" ] || die "downloaded an empty file from $URL"

step "Unpacking"
mkdir -p "$WORK/oket"
tar -xzf "$WORK/$ASSET" -C "$WORK/oket" || die "the archive did not unpack"
[ -x "$WORK/oket/$BIN_NAME" ] || die "no $BIN_NAME in the archive"

# --- 2. the install, which the binary does ---

step "Installing"
"$WORK/oket/$BIN_NAME" --install || die "the install failed"

# --- what is left to do ---

say ""
step "Done"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) say "    Run it:  ${BIN_NAME}" ;;
    *)
        say "    ${BIN_DIR} is not on your PATH. Add it:"
        say "        export PATH=\"${BIN_DIR}:\$PATH\""
        say "    Until then, run it as:  ${BIN_DIR}/${BIN_NAME}"
        ;;
esac

if [ "$KEEP" -eq 1 ]; then
    say ""
    say "    The unpacked release is still at ${WORK}/oket"
fi

say ""
say "    :oket status  says where everything went."
say "    :oket uninstall  takes it all back out."
