#!/usr/bin/env bash
# Build and install the tool.
#
#   Linux (Wayland)  PREFIX=... ./install.sh   binary into $PREFIX/bin
#   macOS            ./install.sh [APP_DIR]    .app bundle + launcher
set -euo pipefail

cd "$(dirname "$0")"

EXECUTABLE="hgsm"

usage() {
	cat <<EOF
usage: ./install.sh [APP_DIR]

  Linux (Wayland)  installs $EXECUTABLE into \${PREFIX:-~/.local}/bin
  macOS            builds a signed "Hex God Screenshot Master.app" in APP_DIR
                   (default ~/Applications) plus a launcher in ~/.local/bin

  -h, --help       show this
EOF
}

# What the binary itself reports, so the bundle cannot drift from it.
built_version() {
	local found
	found="$("zig-out/bin/$EXECUTABLE" --version | awk '{ print $NF }')"
	if [[ -z "$found" ]]; then
		echo "cannot read the version out of zig-out/bin/$EXECUTABLE" >&2
		exit 1
	fi
	echo "$found"
}

path_hint() {
	if [[ ":$PATH:" != *":$1:"* ]]; then
		echo "Add this to your shell config if needed:"
		echo "  export PATH=\"$1:\$PATH\""
	fi
}

install_linux() {
	local prefix="${PREFIX:-$HOME/.local}"

	zig build -Doptimize=ReleaseFast --prefix "$prefix"

	echo "Installed: $prefix/bin/$EXECUTABLE"
	echo
	echo "Run it with:"
	echo "  $EXECUTABLE"
	echo
	path_hint "$prefix/bin"
	echo "For a compositor keybind, point it straight at $prefix/bin/$EXECUTABLE."
}

install_macos() {
	local app_name="Hex God Screenshot Master"
	local app_root="${1:-$HOME/Applications}"
	local app="$app_root/$app_name.app"
	local launcher="$HOME/.local/bin/$EXECUTABLE"
	local icon="assets/icon/icon.icns"

	if [[ ! -f "$icon" ]]; then
		echo "$icon is missing: regenerate it with python3 scripts/gen-icon.py" >&2
		exit 1
	fi

	zig build -Doptimize=ReleaseFast

	local version
	version="$(built_version)"

	# Screen Recording permission is tied to the app's code requirement, so sign
	# with a stable local identity rather than ad-hoc. The signing script creates
	# one if needed and prints the name to use; there is no nested code here, so
	# only the bundle itself is signed.
	local signing_identity
	signing_identity="$(scripts/setup-local-signing.sh)"

	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "zig-out/bin/$EXECUTABLE" "$app/Contents/MacOS/$EXECUTABLE"
	cp "$icon" "$app/Contents/Resources/AppIcon.icns"
	cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$app_name</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.leekool.$EXECUTABLE</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

	codesign --force --sign "$signing_identity" "$app"
	codesign --verify --strict "$app"

	mkdir -p "$(dirname "$launcher")"
	# Two launch paths on purpose. With no arguments the overlay goes through
	# `open` so the process keeps the bundle's identity, and with it the Screen
	# Recording grant the user gave the app. A flag that prints to stdout cannot
	# go through `open` at all (it hands the arguments to launchd, so the caller
	# sees nothing and a running instance just gets focused), so those exec the
	# bundled binary and inherit the caller's own permission instead.
	printf '#!/bin/sh\n# No arguments: the overlay, launched as the app.\nif [ $# -eq 0 ]; then\n\texec open -a %q\nfi\n# Arguments: run the bundled binary so stdout and exit status reach the caller.\nexec %q "$@"\n' \
		"$app" "$app/Contents/MacOS/$EXECUTABLE" >"$launcher"
	chmod +x "$launcher"

	echo "Installed: $app"
	echo "Launcher:  $launcher"
	echo "Version:   $version"
	echo
	echo "On first launch the overlay asks for Screen Recording: grant it to"
	echo "\"$app_name\" in System Settings > Privacy & Security > Screen & System"
	echo "Audio Recording, then run it again. Flags (--pick, --shot, --info,"
	echo "--version) exec the bundled binary directly, so they are attributed to"
	echo "whatever launched them instead of to the app."
	echo
	path_hint "$(dirname "$launcher")"
}

case "$(uname -s)" in
Darwin) os="macos" ;;
Linux) os="linux" ;;
*)
	echo "hgsm supports linux (wayland) and macos; got $(uname -s)." >&2
	exit 1
	;;
esac

if [[ $# -gt 0 ]]; then
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	if [[ "$os" != macos ]]; then
		echo "the linux install takes no arguments (use PREFIX=... to relocate)" >&2
		exit 2
	fi
	if [[ $# -gt 1 ]]; then
		echo "at most one APP_DIR argument" >&2
		exit 2
	fi
fi

if ! command -v zig >/dev/null; then
	echo "zig is not on PATH (https://ziglang.org/download/)" >&2
	exit 1
fi

if [[ "$os" == macos ]]; then
	install_macos "$@"
else
	install_linux
fi
