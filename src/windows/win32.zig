//! The Win32 surface the windows frontend needs, declared by hand.
//!
//! Why hand-written instead of `@cImport`: the same reason `src/macos/objc.zig`
//! gives. `@cImport` would make the build need a windows SDK (only zig's bundled
//! mingw-w64 happens to have the headers, and the linux and macos builds would
//! still carry the dependency). Declaring the entry points makes the whole
//! frontend a description of the ABI it uses, and lets the shared core keep
//! compiling for the other two platforms unchanged.
//!
//! Only the kernel32/user32/gdi32 calls this tool actually makes are here, plus
//! the structs they pass. Calling convention is the Win64 one (`callconv(.winapi)`
//! is the x64 default anyway, spelled out because it matters on 32-bit targets).

const std = @import("std");

pub const BOOL = i32;
pub const UINT = u32;
pub const DWORD = u32;
pub const ATOM = u16;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const HANDLE = *anyopaque;
pub const HWND = HANDLE;
pub const HDC = HANDLE;
pub const HBITMAP = HANDLE;
pub const HINSTANCE = HANDLE;
pub const HCURSOR = HANDLE;
pub const HGLOBAL = HANDLE;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: RECT) i32 {
        return self.right - self.left;
    }

    pub fn height(self: RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const SIZE = extern struct { cx: i32, cy: i32 };

/// `AC_SRC_OVER` with per-pixel alpha, for a premultiplied 32bpp source: the
/// only blend a layered window needs from us.
pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = 0,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 1,
};

pub const UPDATELAYEREDWINDOWINFO = extern struct {
    cbSize: DWORD,
    hdcDst: ?HDC,
    pptDst: ?*const POINT,
    psize: ?*const SIZE,
    hdcSrc: ?HDC,
    pptSrc: ?*const POINT,
    crKey: DWORD,
    pblend: ?*const BLENDFUNCTION,
    dwFlags: DWORD,
    prcDirty: ?*const RECT,
};

pub const WNDPROC = *const fn (hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: ?WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HANDLE,
    hCursor: ?HCURSOR,
    hbrBackground: ?HANDLE,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub const MONITORENUMPROC = *const fn (monitor: ?HANDLE, dc: ?HDC, rect: *RECT, data: LPARAM) callconv(.winapi) BOOL;

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]DWORD,
};

pub const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: DWORD,
    hwndTarget: ?HWND,
};

pub const RAWINPUTHEADER = extern struct {
    dwType: DWORD,
    dwSize: DWORD,
    hDevice: ?HANDLE,
    wParam: WPARAM,
};

pub const RAWMOUSE = extern struct {
    usFlags: u16,
    /// The `ulButtons` arm of the C union; this frontend reads no buttons from
    /// raw input, the window messages carry them.
    buttons: u32,
    ulRawButtons: u32,
    lLastX: i32,
    lLastY: i32,
    ulExtraInformation: u32,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const ws_popup: UINT = 0x8000_0000;
pub const ws_ex_topmost: DWORD = 0x0000_0008;
pub const ws_ex_toolwindow: DWORD = 0x0000_0080;
/// The window's pixels come from `UpdateLayeredWindowIndirect`, presented as one
/// atomic DWM transaction, instead of being painted piecemeal into a
/// redirection surface the compositor can read halfway through.
pub const ws_ex_layered: DWORD = 0x0008_0000;
pub const ulw_alpha: DWORD = 0x0000_0002;

pub const sw_hide: i32 = 0;
pub const hwnd_topmost: HWND = @ptrFromInt(std.math.maxInt(usize));
pub const swp_noactivate: UINT = 0x0010;
pub const swp_showwindow: UINT = 0x0040;

pub const wm_destroy: UINT = 0x0002;
pub const wm_setcursor: UINT = 0x0020;
pub const wm_mousemove: UINT = 0x0200;
pub const wm_lbuttondown: UINT = 0x0201;
pub const wm_lbuttonup: UINT = 0x0202;
pub const wm_rbuttondown: UINT = 0x0204;
pub const wm_mousewheel: UINT = 0x020A;
pub const wm_mousehwheel: UINT = 0x020E;
pub const wm_mouseactivate: UINT = 0x0021;
pub const wm_keydown: UINT = 0x0100;
pub const wm_input: UINT = 0x00FF;

pub const ma_activate: LRESULT = 1;

pub const vk_escape: usize = 0x1B;
pub const vk_shift: usize = 0x10;
pub const vk_oem_minus: usize = 0xBD;
pub const vk_oem_plus: usize = 0xBB;
pub const vk_subtract: usize = 0x6D;
pub const vk_add: usize = 0x6B;

pub const pm_remove: UINT = 0x0001;
pub const qs_allinput: UINT = 0x04FF;
pub const mwmo_inputavailable: DWORD = 0x0004;

/// `HWND_MESSAGE`, i.e. `(HWND)-3`: the parent that makes a window message-only.
pub const hwnd_message: HWND = @ptrFromInt(std.math.maxInt(usize) - 2);

pub const cf_dib: UINT = 8;
pub const cf_unicode_text: UINT = 13;

pub const gmem_moveable: UINT = 0x0002;
pub const dib_rgb_colors: UINT = 0;

pub const srccopy: DWORD = 0x00CC_0020;
/// Include layered windows (menus, HUDs and other overlays) in a desktop grab.
pub const captureblt: DWORD = 0x4000_0000;
pub const bi_rgb: DWORD = 0;

pub const monitorinfof_primary: DWORD = 1;

pub const ridev_inputsink: DWORD = 0x0000_0100;
pub const ridev_remove: DWORD = 0x0000_0001;
pub const rim_typemouse: DWORD = 0;
pub const rid_input: UINT = 0x1000_0003;
/// Set in `RAWMOUSE.usFlags` when the device reports positions, not deltas.
pub const mouse_move_absolute: u16 = 0x01;
/// ... and when those positions span the whole virtual desktop rather than just
/// the primary monitor.
pub const mouse_virtual_desktop: u16 = 0x02;

pub const attach_parent_process: DWORD = 0xFFFF_FFFF;
pub const open_existing: DWORD = 3;

pub const invalid_handle_value: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const std_output_handle: DWORD = 0xFFFF_FFF5;
pub const std_error_handle: DWORD = 0xFFFF_FFF4;

/// CreateFileW
pub const generic_write: DWORD = 0x4000_0000;
pub const generic_read: DWORD = 0x8000_0000;
pub const file_share_read: DWORD = 0x0000_0001;
pub const file_share_write: DWORD = 0x0000_0002;
pub const create_new: DWORD = 0x0000_0001;
pub const file_attribute_normal: DWORD = 0x0000_0080;

/// The `GetLastError` values `save.zig` maps onto its own error set.
pub const error_file_not_found: DWORD = 2;
pub const error_path_not_found: DWORD = 3;
pub const error_access_denied: DWORD = 5;
pub const error_file_exists: DWORD = 80;
pub const error_already_exists: DWORD = 183;

/// GetDpiForMonitor's first argument; the effective (scaled) DPI, not the
/// hardware one, is what the overlay has to size itself against.
pub const mdt_effective_dpi: i32 = 0;

pub const idc_arrow: [*:0]const u16 = @ptrFromInt(32512);

// ---------------------------------------------------------------------------
// kernel32
// ---------------------------------------------------------------------------

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: DWORD,
    share_mode: DWORD,
    security: ?*anyopaque,
    disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WriteFile(
    file: HANDLE,
    buffer: [*]const u8,
    count: DWORD,
    written: *DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetStdHandle(which: DWORD, handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(file_name: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn AttachConsole(process_id: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(memory: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(memory: HGLOBAL) callconv(.winapi) ?HGLOBAL;

// ---------------------------------------------------------------------------
// user32
// ---------------------------------------------------------------------------

pub extern "user32" fn RegisterClassW(class: *const WNDCLASSW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: [*:0]const u16,
    window_name: ?[*:0]const u16,
    style: UINT,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: ?HANDLE,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    count: DWORD,
    handles: ?[*]const HANDLE,
    milliseconds: DWORD,
    wake_mask: UINT,
    flags: DWORD,
) callconv(.winapi) DWORD;
pub extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: ?HWND,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateLayeredWindowIndirect(hwnd: HWND, info: *const UPDATELAYEREDWINDOWINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: HDC) callconv(.winapi) i32;
pub extern "user32" fn GetCursorPos(point: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursorPos(x: i32, y: i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn ShowCursor(show: BOOL) callconv(.winapi) i32;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: [*:0]const u16) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowThreadProcessId(hwnd: ?HWND, process_id: ?*DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn AttachThreadInput(attach: DWORD, attach_to: DWORD, attach_it: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
pub extern "user32" fn EnumDisplayMonitors(
    dc: ?HDC,
    clip: ?*const RECT,
    callback: MONITORENUMPROC,
    data: LPARAM,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetMonitorInfoW(monitor: ?HANDLE, info: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterRawInputDevices(
    devices: [*]const RAWINPUTDEVICE,
    count: UINT,
    size: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetRawInputData(
    input: ?HANDLE,
    command: UINT,
    data: ?*anyopaque,
    size: *UINT,
    header_size: UINT,
) callconv(.winapi) UINT;
pub extern "user32" fn OpenClipboard(hwnd: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(format: UINT, data: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) UINT;
pub extern "user32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;

// ---------------------------------------------------------------------------
// gdi32
// ---------------------------------------------------------------------------

pub extern "gdi32" fn GetDeviceCaps(dc: HDC, index: i32) callconv(.winapi) i32;
/// "Flushes the calling thread's current batch" - i.e. waits until pending GDI
/// drawing has actually touched the destination. See `presentDisplay`:
/// without this, a blit out of the canvas can still be reading it while the next
/// frame's compose writes over it.
pub extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateCompatibleDC(dc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(dc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(
    dc: ?HDC,
    info: *const BITMAPINFO,
    usage: UINT,
    bits: *?*anyopaque,
    section: ?HANDLE,
    offset: DWORD,
) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(dc: HDC, object: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn DeleteObject(object: HANDLE) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(
    dst: HDC,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    src: HDC,
    src_x: i32,
    src_y: i32,
    rop: DWORD,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Dynamic user32: the per-monitor-awareness call is windows 10 1703 and later,
// so it is resolved at runtime and its absence costs the scaling declaration,
// not the ability to start.
// ---------------------------------------------------------------------------

pub const SetProcessDpiAwarenessContextFn = *const fn (context: ?HANDLE) callconv(.winapi) BOOL;

/// Declare per-monitor-v2 awareness. Before this, monitor rectangles and cursor
/// positions come back virtualised and every capture is the wrong size.
///
/// `-4` is DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, a negative pseudo
/// pointer, which is why it is a bit cast rather than an address.
pub fn declarePerMonitorAware() void {
    const Library = struct {
        var resolved: bool = false;
        var function: ?SetProcessDpiAwarenessContextFn = null;
    };
    if (!Library.resolved) {
        Library.resolved = true;
        if (GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"))) |module| {
            if (GetProcAddress(module, "SetProcessDpiAwarenessContext")) |address| {
                Library.function = @ptrCast(@alignCast(address));
            }
        }
    }
    const function = Library.function orelse return;
    const context: ?HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
    // Fails harmlessly when a manifest already declared it, which is the case
    // for the shipped binary.
    _ = function(context);
}

// ---------------------------------------------------------------------------
// Dynamic gdi32: the system dpi, which is the scale of the virtualised desktop
// a dpi-unaware process sees. `GetDeviceCaps` on the screen dc answers it on
// every windows this runs on.
// ---------------------------------------------------------------------------

pub const getdevicecaps_logpixelsx: i32 = 88;

pub fn systemDpi() UINT {
    const screen = GetDC(null) orelse return 96;
    defer _ = ReleaseDC(null, screen);
    const dpi = GetDeviceCaps(screen, getdevicecaps_logpixelsx);
    if (dpi <= 0) return 96;
    return @intCast(dpi);
}

// ---------------------------------------------------------------------------
// Dynamic shcore: GetDpiForMonitor is the one call whose DLL is not present on
// every windows this could end up on, so it is resolved at runtime and a
// failure falls back to 96 dpi rather than refusing to start.
// ---------------------------------------------------------------------------

pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetProcAddress(module: HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

pub const GetDpiForMonitorFn = *const fn (monitor: HANDLE, kind: i32, x: *UINT, y: *UINT) callconv(.winapi) i32;

/// The monitor's effective dpi, or 96 when shcore cannot answer.
pub fn monitorDpi(monitor: HANDLE) UINT {
    const Library = struct {
        var resolved: bool = false;
        var function: ?GetDpiForMonitorFn = null;
    };
    if (!Library.resolved) {
        Library.resolved = true;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("shcore.dll");
        if (LoadLibraryW(name)) |module| {
            if (GetProcAddress(module, "GetDpiForMonitor")) |address| {
                Library.function = @ptrCast(@alignCast(address));
            }
        }
    }
    const function = Library.function orelse return 96;
    var x: UINT = 96;
    var y: UINT = 96;
    if (function(monitor, mdt_effective_dpi, &x, &y) != 0) return 96;
    if (x == 0) return 96;
    return x;
}

/// Give the process a console only when it was started from one.
///
/// Built as a windows-subsystem binary so a hotkey launch never flashes a
/// console, which means the C runtime resolved its descriptors at startup with
/// no console to resolve them to. Whatever the process ends up pointed at - a
/// redirected file or pipe, or a console just attached - the descriptors are
/// handed that, once, here.
///
/// A parent shell's redirection wins over its console: `cmd /c hgsm --info >
/// out.txt` must write the file even though cmd has a console to attach to.
pub fn attachParentConsole() void {
    if (!hasStandardOutput()) {
        if (AttachConsole(attach_parent_process) != 0) {
            // The parent had a console: take its handles explicitly, because
            // attaching does not set this process's standard handles.
            if (openConsoleOutput()) |console| {
                _ = SetStdHandle(std_output_handle, console);
                _ = SetStdHandle(std_error_handle, console);
            }
        }
    }
    bindDescriptor(1, std_output_handle);
    bindDescriptor(2, std_error_handle);
}

/// Whether the process was handed somewhere to write, by a shell redirect or
/// otherwise. A windows-subsystem process started from explorer or a keybind
/// has no standard handle at all.
fn hasStandardOutput() bool {
    const handle = GetStdHandle(std_output_handle) orelse return false;
    return handle != invalid_handle_value;
}

fn openConsoleOutput() ?HANDLE {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
    return CreateFileW(
        name,
        generic_write | generic_read,
        file_share_write,
        null,
        open_existing,
        0,
        null,
    );
}

/// Point a C runtime descriptor at the handle the process has for it, unless it
/// already is that handle.
fn bindDescriptor(descriptor: c_int, which: DWORD) void {
    const handle = GetStdHandle(which) orelse return;
    if (handle == invalid_handle_value) return;
    if (handleDescriptor(descriptor) == @as(isize, @intCast(@intFromPtr(handle)))) return;
    const os_descriptor = openOsfHandle(@intFromPtr(handle));
    if (os_descriptor < 0) return;
    _ = dupDescriptor(os_descriptor, descriptor);
}

extern "c" fn _open_osfhandle(handle: isize, flags: c_int) c_int;
extern "c" fn _dup2(existing: c_int, target: c_int) c_int;
extern "c" fn _get_osfhandle(descriptor: c_int) isize;

fn openOsfHandle(handle: usize) c_int {
    return _open_osfhandle(@intCast(handle), 0);
}

fn dupDescriptor(existing: c_int, target: c_int) c_int {
    return _dup2(existing, target);
}

/// The handle a descriptor currently names, or -1/-2 when it names nothing.
fn handleDescriptor(descriptor: c_int) isize {
    return _get_osfhandle(descriptor);
}
