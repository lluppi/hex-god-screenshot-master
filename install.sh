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
		if [[ "$os" == windows ]]; then
			echo "  set PATH=$1;%PATH%"
		else
			echo "  export PATH=\"$1:\$PATH\""
		fi
	fi
}

install() {
	local prefix="${PREFIX:-$HOME/.local}"
	local binary="$EXECUTABLE"
	[[ "$os" == windows ]] && binary="$EXECUTABLE.exe"

	zig build -Doptimize=ReleaseFast --prefix "$prefix"

	echo "Installed: $prefix/bin/$binary"
	echo
	echo "Run it with:"
	echo "  $binary"
	echo
	path_hint "$prefix/bin"

	if [[ "$os" == windows ]]; then
		echo "Bind a key to $prefix/bin/$binary (autohotkey, powertoys, ...)."
	elif [[ "$os" == macos ]]; then
		echo "Bind a key to $prefix/bin/$binary (aerospace, hammerspoon, skhd, ...)."
	else
		echo "For a compositor keybind, point it straight at $prefix/bin/$binary."
	fi
}

case "$(uname -s)" in
Darwin) os="macos" ;;
Linux) os="linux" ;;
MINGW* | MSYS* | CYGWIN*) os="windows" ;;
*)
	echo "hgsm supports linux (wayland), macos and windows; got $(uname -s)." >&2
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
