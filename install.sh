#!/usr/bin/env bash
# Build and install on Linux (Wayland).
set -euo pipefail

cd "$(dirname "$0")"

EXECUTABLE="hex-god-screenshot-master"
PREFIX="${PREFIX:-$HOME/.local}"

zig build -Doptimize=ReleaseFast --prefix "$PREFIX"

echo "Installed: $PREFIX/bin/$EXECUTABLE"
echo
echo "Run it with:"
echo "  $EXECUTABLE"
echo
if [[ ":$PATH:" != *":$PREFIX/bin:"* ]]; then
	echo "Add this to your shell config if needed:"
	echo "  export PATH=\"$PREFIX/bin:\$PATH\""
	echo
fi
echo "For a compositor keybind, point it straight at $PREFIX/bin/$EXECUTABLE."
