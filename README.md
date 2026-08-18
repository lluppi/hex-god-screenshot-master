# Hex God Screenshot Master

A tiny native macOS tool with one gesture:

- **Hover** to inspect the exact pixel under the cursor in a live circular loupe.
- **Click** to copy that pixel's uppercase hex color, such as `#1D4ED8`.
- **Drag** to measure a rectangle and copy its screenshot to the clipboard.
- **Escape** or right-click to cancel.

Built with AppKit and ScreenCaptureKit. It supports Retina and multiple displays and has no runtime dependencies.

## Requirements

- macOS 14 or newer
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```sh
git clone git@github.com:leekool/hex-god-screenshot-master.git
cd hex-god-screenshot-master
./install.sh
```

The installer creates:

- `~/Applications/Hex God Screenshot Master.app`
- `~/.local/bin/hex-god-screenshot-master`

Run it with:

```sh
hex-god-screenshot-master
```

On first launch, grant **Screen & System Audio Recording** access to **Hex God Screenshot Master**, then launch it again.

If `~/.local/bin` is not on your `PATH`, add this to your shell config:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Keyboard shortcut

Point Raycast, Alfred, AeroSpace, BetterTouchTool, Keyboard Maestro, or a macOS Shortcut at either the installed app or launcher. The app does not register a global hotkey or request Accessibility permission.

Example AeroSpace binding:

```toml
cmd-s = 'exec-and-forget "$HOME/.local/bin/hex-god-screenshot-master"'
```

## Local signing

Screen Recording permission is tied to an app's designated code requirement. Ad-hoc signing changes that identity on every build, which causes repeated permission prompts.

On first install, `scripts/setup-local-signing.sh` creates a trusted, local-only code-signing identity in your login keychain. Subsequent builds retain the same identity and Screen Recording permission. The private key never leaves your machine or enters this repository.

## Develop

```sh
swift build
./install.sh
```

Use the installed app for capture testing. Running through `swift run` may attribute Screen Recording permission to your terminal instead.

## Project layout

```text
Sources/HexGodScreenshotMaster/
├── AppDelegate.swift       # app lifecycle, windows, clipboard coordination
├── MagnifierView.swift     # circular pixel loupe and live hex badge
├── ScreenCapture.swift     # ScreenCaptureKit capture and color sampling
├── Selection.swift         # click/drag state and selection overlay
└── HexGodScreenshotMasterApp.swift # executable entry point
```
