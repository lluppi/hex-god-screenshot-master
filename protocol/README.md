# Vendored Wayland protocol bindings

`src/linux` talks to the compositor through libwayland directly (see
`src/linux/wl.zig`), so it needs the client-side glue that `wayland-scanner`
normally generates. Those files are committed here so that building needs no
scanner, no headers and no XML — only `libwayland-client.so` and
`libxkbcommon.so` at compile and run time.

`xml/` holds the protocol descriptions; `generated/` holds what
`wayland-scanner` produced from them.

| protocol | why |
| --- | --- |
| `wlr-layer-shell-unstable-v1` | full-output overlay surfaces on the overlay layer |
| `wlr-screencopy-unstable-v1` | grabbing the screen baseline and the final screenshot |
| `xdg-output-unstable-v1` | real logical output geometry (fractional scale aware) |
| `viewporter` | mapping a 1:1 physical buffer onto a fractional-scaled output |
| `xdg-shell` | pulled in by layer-shell: its `get_popup` request references `xdg_popup` |

## Regenerating

```sh
# from the repository root
SCANNER=wayland-scanner
for name in xdg-shell xdg-output-unstable-v1 viewporter \
            wlr-layer-shell-unstable-v1 wlr-screencopy-unstable-v1; do
    "$SCANNER" client-header "protocol/xml/$name.xml" "protocol/generated/$name.h"
    "$SCANNER" private-code  "protocol/xml/$name.xml" "protocol/generated/$name.c"
done
```

Sources:

* `wlr-*` from <https://gitlab.freedesktop.org/wlroots/wlr-protocols>
* `xdg-*` and `viewporter` from `wayland-protocols` (`/usr/share/wayland-protocols`)

`wl_registry`, `wl_compositor`, `wl_surface` and friends come from
libwayland-client itself and are declared by hand in `src/linux/wl.zig`.
