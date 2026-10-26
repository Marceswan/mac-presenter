#!/usr/bin/env bash
# Get Sparkle's command-line tools (generate_keys, generate_appcast) for the pinned version.
# Usage: scripts/sparkle-tools.sh
# Output: the absolute path of the tools folder, on stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"  # Sparkle-2.10.0.tar.xz
DIR="$ROOT/build/sparkle/$SPARKLE_VERSION"
BIN="$DIR/bin"

fail() { echo "sparkle-tools: $*" >&2; exit 1; }

if [ ! -x "$BIN/generate_appcast" ]; then
  mkdir -p "$DIR"
  TARBALL="$DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  gh release download "$SPARKLE_VERSION" -R sparkle-project/Sparkle -p "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$DIR" --clobber >&2
  ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
    rm -f "$TARBALL"
    fail "Sparkle $SPARKLE_VERSION tarball SHA-256 mismatch (got $ACTUAL). The download is deleted."
  fi
  tar -xJf "$TARBALL" -C "$DIR"
  [ -x "$BIN/generate_appcast" ] || fail "the tarball has no bin/generate_appcast"
fi
echo "$BIN"
