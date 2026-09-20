# hex god screenshot master

i wanted a screenshot tool that's click to copy a pixel's hex code to clipboard, and drag to copy a screenshot to clipboard


| platform | overlay | capture | clipboard |
| --- | --- | --- | --- |
| linux (wayland) | `wlr-layer-shell` surface per output | `zwlr-screencopy` | `wl_data_source` |
| macos | borderless `NSWindow` per display | `CGDisplayCreateImage` | `NSPasteboard` |


no runtime dependencies beyond `libc`, `libwayland-client` and `libxkbcommon` on linux

## install

`./install.sh --help`.

building needs zig 0.16.0

### linux (wayland)

```sh
git clone git@github.com:lluppi/hex-god-screenshot-master.git
cd hex-god-screenshot-master
./install.sh                      # into ~/.local/bin
PREFIX=/usr/local ./install.sh    # or somewhere else
```

bind it in your compositor, for example hyprland:

```conf
bind = SUPER, S, exec, hgsm
```

needs `wlr-layer-shell` and `wlr-screencopy`, which wlroots compositors and
hyprland provide. gnome and kde wayland do not - says so and exits

### macos

```sh
./install.sh [APP_DIR]   # .app with stable local signing + launcher (default ~/Applications)
```

on first launch grant **Screen & System Audio Recording**, then launch again
point raycast, aerospace, or a shortcut at the launcher

## command line

```text
hgsm                # the overlay
hgsm --pick X,Y     # print and copy the hex of a pixel
hgsm --shot X,Y,W,H # copy a rectangle as a PNG
hgsm --info         # outputs/displays and their scales
hgsm --version      # the version
```

`--pick` and `--shot` take logical coordinates, which is what compositors and the
mac window server report for the cursor, so they compose with anything that can
print a pointer position:

```sh
hgsm --pick "$(hyprctl cursorpos | tr -d ' ')"
```
