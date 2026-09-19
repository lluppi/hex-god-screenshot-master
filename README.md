# Hex God Screenshot Master

One gesture, three outcomes:

- **Hover** to inspect the exact pixel under the cursor in a live circular loupe.
- **Click** to copy that pixel's uppercase hex colour, such as `#1D4ED8`.
- **Drag** to measure a rectangle and copy its screenshot to the clipboard, with
  a live `W × H px` readout following the cursor.
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
│   ├── font.zig          # anti-aliased bitmap text from font_data.zig
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
  window geometry, and therefore what `--pick`, `--shot` and `hyprctl cursorpos`
  speak. The gesture state machine and the click/drag threshold work in these
  units.
- **physical** — real device pixels. On a 4096x1728 logical output at 1.25x that
  is 5120x2160. Sampling, cropping, encoding and the `W x H px` readout all
  happen here, so a picked colour is a real screen pixel and the readout is the
  size of the image you actually get: a 500x400 logical drag reports `625 x 500`
  and produces a 625x500 PNG. The original AppKit app counted logical units
  instead, so its readout was always smaller than the screenshot it made.

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
seconds). The payload is copied into the process's own memory first, since it
outlives the call that produced it. On macOS the pasteboard is server side and
the process exits straight away.

### Frame pacing

Each output has two `wl_shm` buffers and they are alternated on every commit. A
buffer the compositor has handed back with `wl_buffer.release` is preferred, but
the client never *waits* for one, and it never waits for a `wl_surface.frame`
callback either: Hyprland holds the buffer it is currently displaying until a
newer one arrives and does not always deliver frame callbacks for layer
surfaces, so a client that insists on either stops painting after a frame or two.
A repaint requested while both buffers look busy is composed anyway; the worst
case is one frame landing in a buffer the compositor is still reading, which is
invisible in practice for a full screen dim.

### Damage

Writes are confined to a damage region, and the region has to include everything
that changed - including things drawn *outside* the selection, like the size
readout that follows the cursor. A repaint that forgets one leaves a stale pill
on screen until the next pointer event, so `updateSelection` unions in the rect
the readout occupied last frame as well as the one it occupies now.

### Anti-aliasing

Nothing in the overlay is drawn with a hard binary edge:

- **The loupe disc** is composited in a single pass: the body, the magnified
  sample, the cell grid and the centre target are stacked per pixel, and only
  then is that pixel blended with the circle's coverage. Order matters here. The
  first attempt drew the body anti-aliased and then stamped the sample over it
  with a hard circular clip, which throws the anti-aliased edge away again - the
  ring was soft but the disc boundary was not. Doing it in one pass also means
  the grid is clipped by the same coverage test, so it cannot escape the circle
  into the corners of the bounding square.
- **The ring** is deliberately thicker than the original hairline. A ~1px curve
  has no pixel area to anti-alias, so it reads as a stair-stepped line however
  good the coverage maths is. It is 2pt of white with a 1pt dark separator just
  inside, so it reads against light and dark content alike.
- **Circles** use analytic coverage: the distance from the pixel centre to the
  edge is ramped across one pixel. A ring's coverage is the outer disc's
  coverage times how far past the inner edge the pixel is.
- **Rounded rectangles** (the badges) compute each row's edges as exact
  positions and blend the boundary pixels by the fraction of themselves inside.
- **Text** is baked by `tools/gen-font.py` at `supersample` times the size it is
  drawn at (4x: a 32x56 ink mask per 8x14 cell) and drawing box filters that mask
  down, weighing every sample by how much of the destination pixel it covers.
  Scaling a 1x ink mask with nearest neighbour - what this did first - gives each
  stroke a different width whenever the scale is not a whole number, which is
  exactly what "jagged text" looks like. On the live 1.25x display the badge text
  goes from 9 distinct luminance levels to 137.

The magnified sample itself stays nearest-neighbour on purpose: the loupe is a
pixel inspector, so its pixels must be the real screen pixels.

Axis-aligned 1px lines (the selection border and the loupe's target square) are
left hard, which is what keeps them crisp.

## Develop

```sh
zig build                 # debug build into zig-out/bin
zig build run -- --info   # build and run
zig build preview         # render the overlay + loupe to zig-out/preview.png
```

`zig build preview` needs no compositor: it draws the shared overlay renderer
over a synthetic screen so the loupe, selection, dim and badges can be inspected
without booting a session. Handy when changing anything in `src/core`. It also
takes `--scale N`, which renders at a display scale other than 1 so fractional
scale behaviour can be checked without a compositor that scales:

```sh
zig build preview -- --scale 1.25
```

`--dev-click X,Y` and `--dev-drag X,Y,W,H` drive a synthetic gesture through the
same functions the pointer handlers call, so the two paths that need a mouse can
be exercised (and photographed, with `--dev-hold MS`) from a script. `--dev-via
X,Y` pauses at a mid point first, which is how the size readout gets tested while
it is moving. They are a development aid for exactly the code that cannot be
reached otherwise, and they ignore the real pointer while running so the gesture
stays deterministic:

```sh
# what a click copies
hex-god-screenshot-master --dev-click 900,300 && wl-paste
# photograph the selection box and its size readout mid drag
hex-god-screenshot-master --dev-drag 600,400,400,300 --dev-hold 4000 &
sleep 1.5 && grim /tmp/box.png
```

Type-check a frontend for the other platform without an SDK or a toolchain:

```sh
zig build-obj src/main.zig -target aarch64-macos -fno-emit-bin
zig build-obj src/main.zig -target x86_64-macos  -fno-emit-bin
```

### Regenerating the baked assets

- Wayland protocol glue: `protocol/README.md`
- Bitmap font: `python3 tools/gen-font.py > src/core/font_data.zig`

`zig build preview` also takes `--scale N`, which renders the overlay at a display
scale other than 1 so fractional-scale behaviour (loupe metrics, the ring, glyph
filtering) can be checked without a compositor that scales:

```sh
zig build preview -- --scale 1.25
```

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
  by `zig build preview`, which needs no compositor, and still is after the
  anti-aliasing work - the magnified sample is deliberately untouched by it.
- anti-aliasing is measured against the previous build rendering the same scene,
  via `zig build preview -- --scale 1.25`, which is the same renderer both
  frontends call:
  - pixels the loupe paints outside its own disc (the grid bleeding into the
    bounding square's corners): **586 -> 0**.
  - angles around the ring whose edge has no intermediate pixel at all, i.e. a
    hard step: **561/720 -> 0/720**.
  - badge text distinct luminance levels in a live screenshot: **9 -> 137**, and
    the glyph strokes go from single-width `@` blocks with the stem jumping
    columns to a graded curve.
  - the ring's own luminance along its circumference halves its mean step
    (10.97 -> 5.57) with fully-white pixels dropping 1801 -> 1145 as edges become
    partial coverage.
  - text still decodes to `625×500 px` (1748/1800, the misses being pixels
    sitting on the 50% threshold), and the magnified sample is untouched at
    5092/5092 pixel-exact inside r<51 (outside that is the dark separator ring,
    which is decoration, not sample).

  A live before/after of the grid bleed could not be measured on this box: the
  wallpaper animates, so almost no pixel is identical across two captures, and
  staged static backdrops kept being covered by other windows. The preview
  number is the stronger measurement anyway, being exact and repeatable.
- the click path copies the right colour: `--dev-click 900,300` prints `#656B75`,
  puts `#656B75` on the clipboard and `grim -g "900,300 1x1"` agrees.
- the drag path draws its box and its size readout: photographed mid gesture,
  all four edges are a white 1-2px line at the selection, every sampled interior
  pixel is undimmed against a pre-overlay grab, every sampled exterior pixel is
  dimmed, and the `W × H px` pill beside the cursor decodes glyph by glyph to
  `500×375 px` (1800/1800 sampled pixels) for a logical 400x300 drag, and to
  `625×500 px` (1800/1800) for a logical 500x400 one - the physical size each
  time. Moving the cursor mid drag redraws the pill at the new corner and leaves
  nothing behind at the old one. The screenshot that lands on the clipboard is
  500x375 for that 400x300 selection, and matches a `grim` grab of the region.

Not exercised here: Escape and right-click cancel (no way to inject keys or
buttons without another client on this box - the keyboard is grabbed exclusively
while the overlay is up, so this is the one path that needs a human), and
multi-output layouts, as this machine has one display.

Three bugs found by exercising the two paths above, all fixed: the selection was
never grown out of the zero sized rectangle `begin` creates (so no box was ever
drawn, on either frontend), the clipboard payload pointed at the stack frame of
the function that produced it (so a click copied garbage), and commits were
gated on `wl_buffer.release`, which stalls forever on Hyprland. A fourth bug hit
the size readout the moment it was refactored out of the renderer: its `label()`
took `self` by value and returned a slice into that parameter, so the text drew
as nothing while the pill around it drew fine.

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
