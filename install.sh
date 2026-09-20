#!/usr/bin/env bash
# Build and install hex-god-screenshot-master.
#
#   Linux (Wayland)  installs the binary under $PREFIX (default ~/.local)
#   macOS            builds an .app bundle with stable local signing, plus a
#                    launcher at ~/.local/bin, so Screen Recording permission
#                    survives rebuilds
set -euo pipefail

cd "$(dirname "$0")"

EXECUTABLE="hex-god-screenshot-master"

path_hint() {
	if [[ ":$PATH:" != *":$1:"* ]]; then
		echo "Add this to your shell config if needed:"
		echo "  export PATH=\"$1:\$PATH\""
		echo
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
	local signing_identity="$app_name Local Signing"
	local app_root="${1:-$HOME/Applications}"
	local app="$app_root/$app_name.app"
	local launcher="$HOME/.local/bin/$EXECUTABLE"

	zig build -Doptimize=ReleaseFast

	# Screen Recording permission is tied to the app's code requirement, so sign
	# with a stable local identity rather than ad-hoc.
	if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
		scripts/setup-local-signing.sh >/dev/null
	fi

	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "zig-out/bin/$EXECUTABLE" "$app/Contents/MacOS/$EXECUTABLE"
	cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$app_name</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>dev.leekool.$EXECUTABLE</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

	codesign --force --deep --sign "$signing_identity" "$app"

	mkdir -p "$(dirname "$launcher")"
	printf '#!/bin/sh\nexec open -a %q --args "$@"\n' "$app" >"$launcher"
	chmod +x "$launcher"

	echo "Installed: $app"
	echo "Launcher:  $launcher"
	echo
	echo "On first launch, grant Screen Recording to \"$app_name\" in"
	echo "System Settings > Privacy & Security > Screen & System Audio Recording,"
	echo "then run it again."
	echo
	path_hint "$HOME/.local/bin"
}

case "$(uname -s)" in
Darwin) install_macos "$@" ;;
Linux) install_linux ;;
*)
	echo "hex-god-screenshot-master supports linux (wayland) and macos; got $(uname -s)." >&2
	exit 1
	;;
esac
