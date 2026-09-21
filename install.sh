#!/usr/bin/env bash
# Build and install the tool.
#
#   PREFIX=... ./install.sh    binary into $PREFIX/bin (default ~/.local)

set -euo pipefail

cd "$(dirname "$0")"

EXECUTABLE="hgsm"

usage() {
	cat <<EOF
usage: ./install.sh

  installs $EXECUTABLE into \${PREFIX:-~/.local}/bin

  -h, --help       show this
EOF
}

path_hint() {
	if [[ ":$PATH:" != *":$1:"* ]]; then
		echo "Add this to your shell config if needed:"
		echo "  export PATH=\"$1:\$PATH\""
	fi
}

install() {
	local prefix="${PREFIX:-$HOME/.local}"

	zig build -Doptimize=ReleaseFast --prefix "$prefix"

	echo "Installed: $prefix/bin/$EXECUTABLE"
	echo
	echo "Run it with:"
	echo "  $EXECUTABLE"
	echo
	path_hint "$prefix/bin"

	if [[ "$os" == macos ]]; then
		echo "Bind a key to $prefix/bin/$EXECUTABLE (aerospace, hammerspoon, skhd, ...)."
	else
		echo "For a compositor keybind, point it straight at $prefix/bin/$EXECUTABLE."
	fi
}

case "$(uname -s)" in
Darwin) os="macos" ;;
Linux) os="linux" ;;
*)
	echo "hgsm supports linux (wayland) and macos; got $(uname -s)." >&2
	exit 1
	;;
esac

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
"") ;;
*)
	echo "the install takes no arguments (use PREFIX=... to relocate)" >&2
	usage >&2
	exit 2
	;;
esac

if ! command -v zig >/dev/null; then
	echo "zig is not on PATH (https://ziglang.org/download/)" >&2
	exit 1
fi

install
