//! Minimal libwayland-client bindings plus the handful of protocol requests
//! this tool uses.
//!
//! Why hand-written instead of `@cImport`: the macOS build must not need a
//! wayland install, and the Linux build must not need wayland headers (only the
//! shared library). Declaring the ~25 functions we call ourselves keeps the
//! build to `zig build` with `libwayland-client.so` present.
//!
//! The declared protocol interfaces (`wl_registry_interface` and friends) are
//! exported by libwayland-client; the wlr/xdg ones are defined in the vendored
//! generated C in protocol/generated.

const std = @import("std");
const geom = @import("../core/geom.zig");

/// Every wayland object is passed around as an opaque proxy pointer.
pub const Obj = anyopaque;

pub const Interface = extern struct {
    name: ?[*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*anyopaque,
    event_count: c_int,
    events: ?*anyopaque,
};

/// Mirrors `union wl_argument`.
pub const Argument = extern union {
    i: i32,
    u: u32,
    s: ?[*:0]const u8,
    o: ?*Obj,
    n: u32,
    h: i32,
};

pub const marshal_flag_destroy: u32 = 1;

pub extern fn wl_display_connect(name: ?[*:0]const u8) ?*Obj;
pub extern fn wl_display_disconnect(display: *Obj) void;
pub extern fn wl_display_dispatch(display: *Obj) c_int;
pub extern fn wl_display_dispatch_pending(display: *Obj) c_int;
pub extern fn wl_display_roundtrip(display: *Obj) c_int;
pub extern fn wl_display_flush(display: *Obj) c_int;
pub extern fn wl_display_get_fd(display: *Obj) c_int;
pub extern fn wl_display_get_registry(display: *Obj) ?*Obj;
pub extern fn wl_proxy_get_version(proxy: *Obj) u32;
pub extern fn wl_proxy_add_listener(
    proxy: *Obj,
    implementation: [*]const ?*const fn () callconv(.c) void,
    data: ?*anyopaque,
) c_int;
pub extern fn wl_proxy_marshal_array_flags(
    proxy: *Obj,
    opcode: u32,
    interface: ?*const Interface,
    version: u32,
    flags: u32,
    args: [*]const Argument,
) ?*Obj;

pub extern const wl_registry_interface: Interface;
pub extern const wl_compositor_interface: Interface;
pub extern const wl_shm_interface: Interface;
pub extern const wl_shm_pool_interface: Interface;
pub extern const wl_buffer_interface: Interface;
pub extern const wl_surface_interface: Interface;
pub extern const wl_seat_interface: Interface;
pub extern const wl_pointer_interface: Interface;
pub extern const wl_keyboard_interface: Interface;
pub extern const wl_data_device_manager_interface: Interface;
pub extern const wl_data_device_interface: Interface;
pub extern const wl_data_source_interface: Interface;
pub extern const wl_output_interface: Interface;

pub extern const zwlr_layer_shell_v1_interface: Interface;
pub extern const zwlr_layer_surface_v1_interface: Interface;
pub extern const zwlr_screencopy_manager_v1_interface: Interface;
pub extern const zwlr_screencopy_frame_v1_interface: Interface;
pub extern const zxdg_output_manager_v1_interface: Interface;
pub extern const zxdg_output_v1_interface: Interface;
pub extern const wp_viewporter_interface: Interface;
pub extern const wp_viewport_interface: Interface;
pub extern const zwp_pointer_constraints_v1_interface: Interface;
pub extern const zwp_locked_pointer_v1_interface: Interface;
pub extern const zwp_relative_pointer_manager_v1_interface: Interface;
pub extern const zwp_relative_pointer_v1_interface: Interface;

pub const shm_format_argb8888: u32 = 0;
pub const shm_format_xrgb8888: u32 = 1;
pub const button_released: u32 = 0;
pub const button_pressed: u32 = 1;
pub const seat_capability_pointer: u32 = 1;
pub const seat_capability_keyboard: u32 = 2;
pub const keyboard_keymap_format_xkb_v1: u32 = 1;

pub const axis_vertical: u32 = 0;
pub const axis_horizontal: u32 = 1;

pub const layer_overlay: u32 = 2;

pub const anchor_top: u32 = 1;
pub const anchor_left: u32 = 4;

pub const keyboard_interactivity_exclusive: u32 = 1;

/// `zwp_pointer_constraints_v1.lifetime`. A oneshot constraint is defunct the
/// moment it deactivates, which is exactly what happens whenever the pointer
/// focus moves; the fine cursor has to survive that, so it asks for persistent.
pub const constraint_lifetime_oneshot: u32 = 1;
pub const constraint_lifetime_persistent: u32 = 2;

pub fn fixedToFloat(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

/// The inverse, for the requests that take `wl_fixed_t`.
pub fn floatToFixed(value: f64) i32 {
    return @intFromFloat(@round(value * 256.0));
}

/// Flush outgoing requests, wait up to `timeout_ms` for events, and dispatch
/// whatever arrived. Returns an error once the compositor has hung up.
pub fn pump(display: *Obj, timeout_ms: i32) !void {
    _ = wl_display_flush(display);
    var fds = [_]std.posix.pollfd{.{
        .fd = wl_display_get_fd(display),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch 0;
    if (ready > 0) {
        const flags = fds[0].revents;
        if (flags & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            if (wl_display_dispatch(display) < 0) return error.Disconnected;
            return;
        }
    }
    if (wl_display_dispatch_pending(display) < 0) return error.Disconnected;
}

/// Send a request that creates a new object; returns the new proxy.
pub fn requestNew(
    proxy: *Obj,
    opcode: u32,
    iface: *const Interface,
    version: u32,
    args: []Argument,
) ?*Obj {
    return wl_proxy_marshal_array_flags(proxy, opcode, iface, version, 0, args.ptr);
}

/// Send a request with no new object.
pub fn request(proxy: *Obj, opcode: u32, args: []const Argument) void {
    _ = wl_proxy_marshal_array_flags(proxy, opcode, null, 0, 0, args.ptr);
}

/// Send a destructor request; libwayland frees the proxy afterwards.
pub fn requestDestroy(proxy: *Obj, opcode: u32, args: []const Argument) void {
    _ = wl_proxy_marshal_array_flags(
        proxy,
        opcode,
        null,
        0,
        marshal_flag_destroy,
        args.ptr,
    );
}

/// Writable: libwayland writes marshalled ids back into the array.
pub var no_args = [_]Argument{};

pub fn bind(
    registry: *Obj,
    name: u32,
    iface: *const Interface,
    version: u32,
) ?*Obj {
    var args = [_]Argument{
        .{ .u = name },
        .{ .s = iface.name },
        .{ .u = version },
        .{ .n = 0 },
    };
    return requestNew(registry, 0, iface, version, &args);
}

pub fn getRegistry(display: *Obj, version: u32) ?*Obj {
    var args = [_]Argument{.{ .n = 0 }};
    return requestNew(display, 1, &wl_registry_interface, version, &args);
}

pub fn compositorCreateSurface(compositor: *Obj, version: u32) ?*Obj {
    var args = [_]Argument{.{ .n = 0 }};
    return requestNew(compositor, 0, &wl_surface_interface, version, &args);
}

pub fn shmCreatePool(shm: *Obj, version: u32, fd: i32, size: i32) ?*Obj {
    var args = [_]Argument{ .{ .n = 0 }, .{ .h = fd }, .{ .i = size } };
    return requestNew(shm, 0, &wl_shm_pool_interface, version, &args);
}

pub fn shmPoolCreateBuffer(
    pool: *Obj,
    version: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
) ?*Obj {
    var args = [_]Argument{
        .{ .n = 0 },
        .{ .i = offset },
        .{ .i = width },
        .{ .i = height },
        .{ .i = stride },
        .{ .u = format },
    };
    return requestNew(pool, 0, &wl_buffer_interface, version, &args);
}

pub fn shmPoolDestroy(pool: *Obj) void {
    requestDestroy(pool, 1, &no_args);
}

pub fn bufferDestroy(buffer: *Obj) void {
    requestDestroy(buffer, 0, &no_args);
}

pub fn surfaceAttach(surface: *Obj, buffer: ?*Obj, x: i32, y: i32) void {
    var args = [_]Argument{ .{ .o = buffer }, .{ .i = x }, .{ .i = y } };
    request(surface, 1, &args);
}

pub fn surfaceDamage(surface: *Obj, x: i32, y: i32, width: i32, height: i32) void {
    var args = [_]Argument{
        .{ .i = x },
        .{ .i = y },
        .{ .i = width },
        .{ .i = height },
    };
    request(surface, 2, &args);
}

/// Damage in surface-local *buffer* pixels: the units the overlay works in, so
/// it never has to reason about the surface's own coordinate space.
pub fn surfaceDamageBuffer(surface: *Obj, rect: geom.Rect) void {
    var args = [_]Argument{
        .{ .i = rect.x },
        .{ .i = rect.y },
        .{ .i = rect.w },
        .{ .i = rect.h },
    };
    request(surface, 9, &args);
}

pub fn surfaceSetBufferScale(surface: *Obj, scale: i32) void {
    var args = [_]Argument{.{ .i = scale }};
    request(surface, 8, &args);
}

pub fn surfaceCommit(surface: *Obj) void {
    request(surface, 6, &no_args);
}

pub fn surfaceDestroy(surface: *Obj) void {
    requestDestroy(surface, 0, &no_args);
}

pub fn seatGetPointer(seat: *Obj, version: u32) ?*Obj {
    var args = [_]Argument{.{ .n = 0 }};
    return requestNew(seat, 0, &wl_pointer_interface, version, &args);
}

pub fn seatGetKeyboard(seat: *Obj, version: u32) ?*Obj {
    var args = [_]Argument{.{ .n = 0 }};
    return requestNew(seat, 1, &wl_keyboard_interface, version, &args);
}

pub fn pointerSetCursor(
    pointer: *Obj,
    serial: u32,
    surface: ?*Obj,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    var args = [_]Argument{
        .{ .u = serial },
        .{ .o = surface },
        .{ .i = hotspot_x },
        .{ .i = hotspot_y },
    };
    request(pointer, 0, &args);
}

pub fn dataDeviceManagerCreateSource(manager: *Obj, version: u32) ?*Obj {
    var args = [_]Argument{.{ .n = 0 }};
    return requestNew(manager, 0, &wl_data_source_interface, version, &args);
}

pub fn dataDeviceManagerGetDevice(manager: *Obj, version: u32, seat: *Obj) ?*Obj {
    var args = [_]Argument{ .{ .n = 0 }, .{ .o = seat } };
    return requestNew(manager, 1, &wl_data_device_interface, version, &args);
}

pub fn dataSourceOffer(source: *Obj, mime_type: [*:0]const u8) void {
    var args = [_]Argument{.{ .s = mime_type }};
    request(source, 0, &args);
}

pub fn dataSourceDestroy(source: *Obj) void {
    requestDestroy(source, 1, &no_args);
}

pub fn dataDeviceSetSelection(device: *Obj, source: ?*Obj, serial: u32) void {
    var args = [_]Argument{ .{ .o = source }, .{ .u = serial } };
    request(device, 1, &args);
}

pub fn layerShellGetLayerSurface(
    shell: *Obj,
    version: u32,
    surface: *Obj,
    output: ?*Obj,
    layer: u32,
    namespace: [*:0]const u8,
) ?*Obj {
    var args = [_]Argument{
        .{ .n = 0 },
        .{ .o = surface },
        .{ .o = output },
        .{ .u = layer },
        .{ .s = namespace },
    };
    return requestNew(shell, 0, &zwlr_layer_surface_v1_interface, version, &args);
}

pub fn layerSurfaceSetSize(layer_surface: *Obj, width: u32, height: u32) void {
    var args = [_]Argument{ .{ .u = width }, .{ .u = height } };
    request(layer_surface, 0, &args);
}

pub fn layerSurfaceSetAnchor(layer_surface: *Obj, anchor: u32) void {
    var args = [_]Argument{.{ .u = anchor }};
    request(layer_surface, 1, &args);
}

pub fn layerSurfaceSetExclusiveZone(layer_surface: *Obj, zone: i32) void {
    var args = [_]Argument{.{ .i = zone }};
    request(layer_surface, 2, &args);
}

pub fn layerSurfaceSetKeyboardInteractivity(layer_surface: *Obj, mode: u32) void {
    var args = [_]Argument{.{ .u = mode }};
    request(layer_surface, 4, &args);
}

pub fn layerSurfaceAckConfigure(layer_surface: *Obj, serial: u32) void {
    var args = [_]Argument{.{ .u = serial }};
    request(layer_surface, 6, &args);
}

pub fn layerSurfaceDestroy(layer_surface: *Obj) void {
    requestDestroy(layer_surface, 7, &no_args);
}

pub fn screencopyCaptureOutput(
    manager: *Obj,
    version: u32,
    overlay_cursor: i32,
    output: *Obj,
) ?*Obj {
    var args = [_]Argument{
        .{ .n = 0 },
        .{ .i = overlay_cursor },
        .{ .o = output },
    };
    return requestNew(manager, 0, &zwlr_screencopy_frame_v1_interface, version, &args);
}

pub fn screencopyCaptureOutputRegion(
    manager: *Obj,
    version: u32,
    overlay_cursor: i32,
    output: *Obj,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) ?*Obj {
    var args = [_]Argument{
        .{ .n = 0 },
        .{ .i = overlay_cursor },
        .{ .o = output },
        .{ .i = x },
        .{ .i = y },
        .{ .i = width },
        .{ .i = height },
    };
    return requestNew(manager, 1, &zwlr_screencopy_frame_v1_interface, version, &args);
}

pub fn screencopyFrameCopy(frame: *Obj, buffer: *Obj) void {
    var args = [_]Argument{.{ .o = buffer }};
    request(frame, 0, &args);
}

pub fn screencopyFrameDestroy(frame: *Obj) void {
    requestDestroy(frame, 1, &no_args);
}

pub fn xdgOutputManagerGetOutput(manager: *Obj, version: u32, output: *Obj) ?*Obj {
    var args = [_]Argument{ .{ .n = 0 }, .{ .o = output } };
    return requestNew(manager, 1, &zxdg_output_v1_interface, version, &args);
}

pub fn xdgOutputDestroy(xdg_output: *Obj) void {
    requestDestroy(xdg_output, 0, &no_args);
}

pub fn viewporterGetViewport(viewporter: *Obj, version: u32, surface: *Obj) ?*Obj {
    var args = [_]Argument{ .{ .n = 0 }, .{ .o = surface } };
    return requestNew(viewporter, 1, &wp_viewport_interface, version, &args);
}

pub fn viewportSetDestination(viewport: *Obj, width: i32, height: i32) void {
    var args = [_]Argument{ .{ .i = width }, .{ .i = height } };
    request(viewport, 2, &args);
}

// ---------------------------------------------------------------------------
// pointer lock and relative motion
// ---------------------------------------------------------------------------

/// `zwp_relative_pointer_manager_v1.get_relative_pointer`: the deltas this
/// returns are the raw ones, before the compositor quantises the pointer to
/// whole logical pixels, which is what makes a per-pixel cursor possible.
pub fn relativePointerManagerGetRelativePointer(
    manager: *Obj,
    version: u32,
    pointer: *Obj,
) ?*Obj {
    var args = [_]Argument{ .{ .n = 0 }, .{ .o = pointer } };
    return requestNew(manager, 1, &zwp_relative_pointer_v1_interface, version, &args);
}

pub fn relativePointerDestroy(relative_pointer: *Obj) void {
    requestDestroy(relative_pointer, 0, &no_args);
}

/// `zwp_pointer_constraints_v1.lock_pointer`: pin the real pointer. `region`
/// stays null, which the protocol reads as the whole surface.
pub fn constraintsLockPointer(
    constraints: *Obj,
    version: u32,
    surface: *Obj,
    pointer: *Obj,
    lifetime: u32,
) ?*Obj {
    var args = [_]Argument{
        .{ .n = 0 },
        .{ .o = surface },
        .{ .o = pointer },
        .{ .o = null },
        .{ .u = lifetime },
    };
    return requestNew(constraints, 1, &zwp_locked_pointer_v1_interface, version, &args);
}

/// Where the pointer should sit while it is locked, relative to the surface's
/// top left. Without it the compositor parks it wherever it was when the lock
/// was requested, which is not necessarily where the user is looking.
pub fn lockedPointerSetCursorPositionHint(locked: *Obj, x: f64, y: f64) void {
    var args = [_]Argument{ .{ .i = floatToFixed(x) }, .{ .i = floatToFixed(y) } };
    request(locked, 1, &args);
}

pub fn lockedPointerDestroy(locked: *Obj) void {
    requestDestroy(locked, 0, &no_args);
}

/// Add a listener, casting the listener struct to the function-pointer array
/// libwayland expects.
pub fn addListener(proxy: *Obj, listener: *align(8) const anyopaque, data: *anyopaque) void {
    _ = wl_proxy_add_listener(
        proxy,
        @ptrCast(listener),
        @ptrCast(data),
    );
}

/// A no-op event handler used to fill unused listener slots. libwayland indexes
/// the listener array by event opcode, so every slot the compositor may send
/// must be present even when we ignore the event.
pub fn noop(
    data: ?*anyopaque,
    obj: ?*Obj,
    a: usize,
    b: usize,
    c: usize,
    d: usize,
) callconv(.c) void {
    _ = data;
    _ = obj;
    _ = a;
    _ = b;
    _ = c;
    _ = d;
}

/// xkbcommon bindings, used only to turn the Escape keycode into a decision.
pub const xkb = struct {
    pub extern fn xkb_context_new(flags: u32) ?*anyopaque;
    pub extern fn xkb_context_unref(context: *anyopaque) void;
    pub extern fn xkb_keymap_new_from_string(
        context: *anyopaque,
        string: [*:0]const u8,
        format: u32,
        flags: u32,
    ) ?*anyopaque;
    pub extern fn xkb_keymap_unref(keymap: *anyopaque) void;
    pub extern fn xkb_state_new(keymap: *anyopaque) ?*anyopaque;
    pub extern fn xkb_state_unref(state: *anyopaque) void;
    pub extern fn xkb_state_key_get_one_sym(state: *anyopaque, keycode: u32) u32;

    pub const context_no_flags: u32 = 0;
    pub const keymap_format_text_v1: u32 = 1;
    pub const keymap_compile_no_flags: u32 = 0;
    /// XKB keycode = evdev keycode + 8; Escape is evdev 1.
    pub const keycode_offset: u32 = 8;
    pub const keysym_escape: u32 = 0xff1b;
    pub const keysym_shift_l: u32 = 0xffe1;
    pub const keysym_shift_r: u32 = 0xffe2;
    pub const keysym_minus: u32 = 0x2d;
    pub const keysym_equal: u32 = 0x3d;
    pub const keysym_plus: u32 = 0x2b;
};
