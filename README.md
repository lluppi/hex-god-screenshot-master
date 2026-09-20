# Hex God Screenshot Master

One gesture, three outcomes:

- **Hover** to inspect the pixel under the cursor in a live pixel scope; the
  native pointer hides so the centre target stays unobstructed.
- **Click** to copy that pixel's uppercase hex colour, e.g. `#1D4ED8`.
- **Drag** to measure a rectangle and copy its screenshot, with a live `W × H`
  readout and a compact endpoint scope attached outside the active corner.
- **Escape** or right-click to cancel.

Zig, one shared core and a thin frontend per platform:

| platform | overlay | capture | clipboard |
| --- | --- | --- | --- |
| Linux (Wayland) | `wlr-layer-shell` surface per output | `zwlr-screencopy` | `wl_data_source` |
| macOS | borderless `NSWindow` per display | `CGDisplayCreateImage` | `NSPasteboard` |

One binary name and one set of flags on both platforms. No runtime dependencies
beyond libc, `libwayland-client` and `libxkbcommon` on Linux.

## Install

### Linux (Wayland: Hyprland, Sway, river, niri, ...)

```sh
git clone git@github.com:lluppi/hex-god-screenshot-master.git
cd hex-god-screenshot-master
./install.sh   # to ~/.local/bin, override with PREFIX=...
```

Bind it in your compositor, for example Hyprland:

```conf
bind = SUPER, S, exec, hex-god-screenshot-master
```

Needs `wlr-layer-shell` and `wlr-screencopy`, which wlroots compositors and
Hyprland provide. GNOME and KDE Wayland do not; the tool says so and exits.

### macOS

```sh
./install-macos.sh   # Release build, .app with stable local signing, launcher
```

On first launch grant **Screen & System Audio Recording**, then launch again.
Point Raycast, Alfred, AeroSpace or a Shortcut at the launcher. No global hotkey,
no Accessibility permission.

## Command line

```text
hex-god-screenshot-master                # the overlay
hex-god-screenshot-master --pick X,Y     # print and copy the hex of a pixel
hex-god-screenshot-master --shot X,Y,W,H # copy a rectangle as a PNG
hex-god-screenshot-master --info         # outputs/displays and their scales
```

`--pick` and `--shot` take logical coordinates, which is what compositors and the
mac window server report for the cursor, so they compose with anything that can
print a pointer position:

```sh
hex-god-screenshot-master --pick "$(hyprctl cursorpos | tr -d ' ')"
```

## Layout

```text
src/
├── main.zig              # platform dispatch
├── core/                 # shared, no platform APIs
│   ├── gesture.zig       # click vs drag state machine (4px threshold)
│   ├── interaction.zig   # cursor, scope, selection and damage policy
│   ├── canvas.zig        # ARGB8888 drawing surface, clipped writes
│   ├── color.zig         # #RRGGBB, premultiplied compositing, dimming
│   ├── magnifier.zig     # square pixel scope, target and hex readout
│   ├── overlay.zig       # baseline + dim + selection + size badge
│   ├── badge.zig         # instrument readout geometry and painting
│   ├── font.zig          # anti-aliased bitmap text from font_data.zig
│   ├── sampling.zig      # pixel under the cursor, scope sample extraction
│   ├── png.zig           # PNG encoder
│   ├── cli.zig           # flags
│   └── sys.zig           # write/close/nanosleep/monotonic clock
├── linux/                # Wayland frontend: wl, app, capture, shm
└── macos/                # macOS frontend: objc, app
```

### Coordinate model

Two spaces, converted at the edges of the core:

- **logical** — cursor and window units the compositor or window server reports,
  and what `--pick`, `--shot` and `hyprctl cursorpos` speak. The gesture state
  machine and the drag threshold work here.
- **physical** — real device pixels. A 4096x1728 logical output at 1.25x is
  5120x2160. Sampling, cropping, encoding and the `W × H` readout happen here, so
  a pick is a real screen pixel and the readout matches the image you get: a
  500x400 logical drag reports `625 × 500` and produces a 625x500 PNG.

The per-output scale is derived from the baseline capture size divided by the
logical size — never guessed from `wl_output.scale` (an integer) or
`backingScaleFactor` alone.

### Why the scope magnifies a baseline

`zwlr_screencopy` captures the composited output *including our own overlay*, so
a live scope would magnify itself. Each output is grabbed once, before any
surface exists, and everything is derived from that snapshot: the scope magnifies
the baseline, the overlay is lightly dimmed outside the selection, and the final
screenshot is a fresh grab taken after the surfaces are unmapped. macOS does the
same with `CGDisplayCreateImage`, keeping the frontends behaviourally identical.

### Clipboard, damage, pacing

- On Wayland the clipboard lives in the owning client, so after a copy the
  process serves `wl_data_source` until another client takes the selection (or a
  minute passes, or a paste has been idle five seconds). The payload is copied
  into our own memory first, since it outlives the call that produced it. On
  macOS the pasteboard is server side and the process exits straight away.
- Writes are confined to a damage region that has to include everything that
  changed — including the size readout drawn outside the selection — or a stale
  readout lingers until the next pointer event.
- Each output has two `wl_shm` buffers, alternated on every commit. We never wait
  for `wl_buffer.release` or a `wl_surface.frame` callback: Hyprland stalls a
  client that does. A repaint while both look busy is composed anyway; the worst
  case is one frame landing in a buffer still being read, invisible for a full
  screen dim.

### Rendering

The overlay is treated as an optical instrument rather than a floating app
window. The square scope uses paired light and dark rails, with its inner rail
sharing the data grid's ink and weight. The selection uses a one-point difference
edge: it inverts the pixels beneath it, snapping mid-greys to black or white where
plain inversion would disappear. The existing exterior dim supplies the quiet
dark field without making the edge heavier. While dragging, three 3x3 grids wrap
the outside of the active corner as an L, showing both edge neighbourhoods and
the outward diagonal without covering the capture. The endpoint pixel occupies
the cell that physically touches the corner. The size plate spans the six-cell
cluster width below a bottom corner or above a top corner. Its compact type keeps
the bar shallow and scales down further only for unusually large dimensions. Near a screen edge the
instrument falls back to the floating size plate if the full cluster cannot fit. The attached hex plate
carries the sampled colour as its only chromatic accent. Magnified samples stay
nearest-neighbour so their pixel grids remain literal.

Text is baked by `tools/gen-font.py` at 4x (a 32x56 ink mask per 8x14 cell) from
the specimen outlines in `assets/font/`, and box-filtered down when drawn, since
nearest-neighbour scaling gives every stroke a different width. The custom font
is the visual constant across the scope and selection readouts.

## Develop

```sh
zig build                           # debug build into zig-out/bin
zig build run -- --info             # build and run
zig build preview                   # render overlay + scope to zig-out/preview.png
zig build preview -- --scale 1.25   # check fractional scale without a compositor
```

`zig build preview` needs no compositor: it draws the shared overlay renderer
over a synthetic screen, so the scope, selection, dim and readouts can be inspected
without booting a session.

`--dev-click X,Y` and `--dev-drag X,Y,W,H` drive a synthetic gesture through the
same functions the pointer handlers call, so the two paths that need a mouse can
be exercised from a script. `--dev-hold MS` photographs them; `--dev-via X,Y`
pauses mid-way first, which tests the moving readout. They ignore the real
pointer so the gesture stays deterministic.

```sh
hex-god-screenshot-master --dev-drag 600,400,400,300 --dev-hold 4000 &
sleep 1.5 && grim /tmp/box.png
```

Type-check the other platform's frontend without an SDK or toolchain:

```sh
zig build-obj src/main.zig -target aarch64-macos -fno-emit-bin
zig build-obj src/main.zig -target x86_64-macos  -fno-emit-bin
```

### Regenerating the baked assets

- Wayland protocol glue: `protocol/README.md`
- Glyph outlines from the specimen image: `assets/font/README.md`
- Bitmap font from those outlines: `python3 tools/gen-font.py > src/core/font_data.zig`

## Status

Exercised on Hyprland 0.56, one 5120x2160 output at scale 1.25, cross-checked
against `grim` and `wl-paste`:

- geometry and scale agree with `hyprctl monitors`; `--pick` returns the same
  colour as `grim` for the same pixel and as the overlay's hex badge.
- `--shot` is byte-identical to `grim` for regions with an exact physical size
  (any multiple of 4 logical pixels at 1.25x). Between pixels the two differ by
  at most one row or column, keeping the compositor's rounding.
- the click path copies the right colour: `--dev-click 900,300` prints `#656B75`
  and the clipboard and `grim` agree.
- the drag path draws its box and readout: two-tone rails at the selection,
  interior undimmed, exterior dimmed, and the `W × H` plate decodes to `500×375` for a
  400x300 drag and `625×500` for a 500x400 one — the physical size each time. The
  clipboard PNG matches a `grim` grab of the region.
- the scope's nearest-neighbour magnification can be inspected at fractional
  display scales with `zig build preview -- --scale 1.25`.

Not exercised: Escape and right-click cancel (the keyboard is grabbed
exclusively while the overlay is up, so this needs a human), and multi-output
layouts, as this machine has one display.

The macOS frontend is written and type-checked but never compiled against a real
SDK or run, having been written on Linux. Highest risk on first run: the
borderless window setup, flipped/unflipped view coordinates, and
`CGDisplayCreateImage` (deprecated since macOS 14 but still functional).

## Previous implementation

The original AppKit + ScreenCaptureKit Swift version is in git history (the
commit before the rewrite). `scripts/setup-local-signing.sh` is unchanged from
it.
