# Hex God Screenshot Master

One gesture, three outcomes:

- **Hover** to inspect the exact pixel under the cursor in a live circular loupe.
- **Click** to copy that pixel's uppercase hex colour, such as `#1D4ED8`.
- **Drag** to measure a rectangle and copy its screenshot to the clipboard.
- **Escape** or right-click to cancel.

Rewritten in zig with one shared core and a thin frontend per platform:

| platform | overlay | capture | clipboard |
| --- | --- | --- | --- |
| Linux (Wayland) | `wlr-layer-shell` surface per output | `zwlr-screencopy` | `wl_data_source` |
| macOS | borderless `NSWindow` per display | `CGDisplayCreateImage` | `NSPasteboard` |

There is one binary name and one set of flags on both platforms, and no runtime
dependencies beyond libc, `libwayland-client` and `libxkbcommon` on Linux.

## Install

### Linux (Wayland: Hyprland, Sway, river, niri, ...)

```sh
git clone git@github.com:lluppi/hex-god-screenshot-master.git
cd hex-god-screenshot-master
./install.sh
```

Installs to `~/.local/bin/hex-god-screenshot-master` (override with `PREFIX=...`).

Point a compositor keybind at it, for example in Hyprland:

```conf
bind = SUPER, S, exec, hex-god-screenshot-master
```

Needs the `wlr-layer-shell` and `wlr-screencopy` protocols, which wlroots-based
compositors and Hyprland all provide. GNOME and KDE Wayland do not, so this will
tell you so and exit.

### macOS

```sh
./install-macos.sh
```

Builds with `zig build -c Release`, assembles
`~/Applications/Hex God Screenshot Master.app`, signs it with a stable local
identity (see `scripts/setup-local-signing.sh`) and drops a launcher at
`~/.local/bin/hex-god-screenshot-master`.

On first launch, grant **Screen & System Audio Recording** to
**Hex God Screenshot Master**, then launch it again.

Point Raycast, Alfred, AeroSpace, BetterTouchTool or a macOS Shortcut at the
launcher. The app registers no global hotkey and asks for no Accessibility
permission.

## Command line

```text
hex-god-screenshot-master                # the overlay
hex-god-screenshot-master --pick X,Y     # print and copy the hex of a pixel
hex-god-screenshot-master --shot X,Y,W,H # copy a rectangle as a PNG
hex-god-screenshot-master --info         # outputs/displays and their scales
```

`--pick` and `--shot` take logical coordinates, which is what both compositors
and the mac window server report for the cursor, so they compose nicely with
anything that can print a pointer position.

```sh
hex-god-screenshot-master --pick "$(hyprctl cursorpos | tr -d ' ')"
```

## How it works

```text
src/
├── main.zig              # platform dispatch
├── core/                 # everything shared, no platform APIs
│   ├── gesture.zig       # click vs drag state machine (4px threshold)
│   ├── canvas.zig        # ARGB8888 drawing surface, clipped writes
│   ├── color.zig         # #RRGGBB, premultiplied compositing, dimming
│   ├── magnifier.zig     # the loupe: 21x21 sample, grid, target, hex badge
│   ├── overlay.zig       # baseline + dim + selection + size badge compositor
│   ├── font.zig          # bitmap text from font_data.zig
│   ├── sampling.zig      # pixel under the cursor, loupe sample extraction
│   ├── png.zig           # PNG encoder (std.compress.flate for the zlib stream)
│   ├── cli.zig           # flags
│   └── sys.zig           # write/close/nanosleep/monotonic clock
├── linux/                # Wayland frontend
│   ├── wl.zig            # hand written libwayland-client + protocol bindings
│   ├── app.zig           # outputs, layer surfaces, pointer, keyboard, clipboard
│   ├── capture.zig       # zwlr_screencopy grabs
│   └── shm.zig           # wl_shm buffers
└── macos/                # macOS frontend
    ├── objc.zig          # objc runtime, AppKit and CoreGraphics declarations
    └── app.zig           # windows, events, capture, pasteboard
```

### Coordinate model

Two spaces, converted at the edges of the core:

- **logical** — what the compositor or window server reports for the cursor and
  window geometry. The gesture state machine, the click/drag threshold and the
  `W x H px` badge all work in logical units, exactly like the original.
- **physical** — real device pixels. On a 4096x1728 logical output at 1.25x that
  is 5120x2160. Sampling, cropping and encoding happen here, so a picked colour
  is a real screen pixel.

The per-output scale is never guessed from `wl_output.scale` (an integer, so
useless at 1.25x) or from `backingScaleFactor` alone: it is derived from the
size of the baseline capture divided by the logical size.

### Why the loupe magnifies a baseline

`zwlr_screencopy` captures the composited output *including our own overlay*, so
a live loupe would magnify itself. Instead each output is grabbed once, before
any surface exists, and everything is derived from that snapshot:

- the loupe magnifies the baseline, so its centre is exactly the pixel under the
  cursor and the hex badge matches what the loupe shows,
- the overlay is a copy of the baseline with a 4% dim, minus the selection,
- the final screenshot is a *fresh* grab taken after the surfaces are unmapped,
  so it shows the desktop rather than our dimming.

The mac frontend does the same thing with `CGDisplayCreateImage`, which keeps the
two frontends behaviourally identical.

### Clipboard lifetime

On Wayland the clipboard lives in the client that owns the selection, so after
copying, the process keeps serving the `wl_data_source` until another client
takes the selection (or a minute passes, or a paste has been idle for five
seconds). On macOS the pasteboard is server side and the process exits straight
away.

## Develop

```sh
zig build                 # debug build into zig-out/bin
zig build run -- --info   # build and run
zig build preview         # render the overlay + loupe to zig-out/preview.png
```

`zig build preview` needs no compositor: it draws the shared overlay renderer
over a synthetic screen so the loupe, selection, dim and badges can be inspected
without booting a session. Handy when changing anything in `src/core`.

Type-check a frontend for the other platform without an SDK or a toolchain:

```sh
zig build-obj src/main.zig -target aarch64-macos -fno-emit-bin
zig build-obj src/main.zig -target x86_64-macos  -fno-emit-bin
```

### Regenerating the baked assets

- Wayland protocol glue: `protocol/README.md`
- Bitmap font: `python3 tools/gen-font.py > src/core/font_data.zig`

## Status

### Linux / Wayland

Built and exercised on Hyprland 0.56, one 5120x2160 output at scale 1.25, cross
checked against `grim` and `wl-paste` on the same screen:

- logical geometry and scale: xdg-output reports 4096x1728 logical, the baseline
  grab is 5120x2160, so the derived scale is 1.25 - matching `hyprctl monitors`.
- `--pick` returns the same colour `grim` does for the same pixel, and the same
  colour the overlay's hex badge shows: the badge in a live screenshot decodes,
  glyph by glyph, to `#2C2A30`, which is what `--pick 1412,696` printed and what
  `grim -g "1412,696 1x1"` contains.
- `--shot` is byte-identical to `grim` for regions whose physical size is exact
  (any multiple of 4 logical pixels at 1.25x, for example 64x48 -> 80x60). For
  regions that land between physical pixels the two differ by at most one row or
  column: this keeps the compositor's own rounding instead of truncating.
- overlay: the full screen dim is exactly `246/256` per channel, the loupe is
  centred on the cursor pixel at the 1.25x-metric size with its ring, grid and
  target square, and the undimmed selection plus its size badge composite
  correctly.
- the loupe's magnify maths is verified pixel-exactly (5288/5288 sampled pixels)
  by `zig build preview`, which needs no compositor.

Not exercised here: Escape and right-click cancel (no way to inject input
without another client), the drag interaction end to end (same reason), and
multi-output layouts, as this machine has one display.

### macOS

Written and type-checked with `zig build-obj src/main.zig -target {aarch64,
x86_64}-macos -fno-emit-bin`, but never compiled against a real SDK or run,
because it was written on Linux. Expect to iterate on first run; the highest
risk areas are the borderless window setup, the flipped/unflipped view
coordinate handling in `viewPoint`/`paintRegion`, and `CGDisplayCreateImage`
(deprecated since macOS 14 but still functional).

## Previous implementation

The original AppKit + ScreenCaptureKit Swift version is in git history (the
commit before the rewrite). `scripts/setup-local-signing.sh` is unchanged from
it.
