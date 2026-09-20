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
hgsm --gain N       # overlay cursor speed (default 0.5)
hgsm --no-fine      # let the compositor's cursor drive the overlay
hgsm --info         # outputs/displays, their scales, the fine pointer protocols
hgsm --version      # the version
```

`--pick` and `--shot` take logical coordinates, which is what compositors and the
mac window server report for the cursor, so they compose with anything that can
print a pointer position:

```sh
hgsm --pick "$(hyprctl cursorpos | tr -d ' ')"
```

## the fine cursor

the overlay's cursor is not the compositor's cursor. it is hgsm's own, in global
logical coordinates, advanced by the pointer's raw deltas
(`zwp_relative_pointer_v1` on wayland, the mouse's own deltas on macos) at
`--gain` logical pixels per unit.

that matters on scaled outputs, which is where the first version was hard to aim.
compositors quantise the pointer to whole *logical* pixels, and on a 5120x2160
output at scale 1.25 a logical pixel is 1.25 *physical* pixels, which is what the
loupe and the size readout count. so the compositor alone can address about four
of every five screen pixels, and the cell under the cursor jumps by one or two at
a time. a delta is not quantised, so this cursor lands where the arithmetic says
and every pixel of the display can be reached.

`--gain` is how much hand travel that costs: 1 matches the compositor's own
cursor exactly, 0.5 (the default) is twice as fine, and lower keeps going until
the cursor is unusable. it can be changed while the overlay is up with `-` and
`=`, and one wheel detent moves the cursor exactly one physical pixel (with shift
for the other axis) when the last pixel has to be exact. `--no-fine` gives the old
behaviour back, which is also what a compositor without `zwp_relative_pointer_v1`
gets.

hgsm also asks for `zwp_pointer_constraints_v1` to park the real pointer while the
overlay is up and supplies the fine cursor's final position as the compositor's
unlock hint. hyprland reports the lock as active on a layer surface without
actually holding the pointer, so there the pointer still drifts with the hand -
the fine cursor does not depend on it, and the mouse is hidden either way.
