#!/usr/bin/env bash
# A plugin that builds itself. stage.sh hands over the source and output directories and the
# header directories for whichever layout it found; what happens in between is this file's
# business, and $NAME.so in $2 is the only thing it owes back.
set -euo pipefail
SRC="$1"
OUT="$2"
zig c++ -shared -std=c++17 -fPIC -O2 -fvisibility=hidden \
    -I"$OKET_SEAM" -o "$OUT/ownplug.so" "$SRC/ownplug.cxx"
