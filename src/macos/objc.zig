//! The Objective-C runtime, AppKit and CoreGraphics surface the macOS frontend
//! uses, declared by hand.
//!
//! Two rules make this work without an SDK:
//!
//!  * Messages go through `msgSend`, which builds the *exact* non-variadic
//!    function type for the call and casts `objc_msgSend` to it. Calling
//!    `objc_msgSend` as a C variadic would be wrong on arm64, where variadic
//!    arguments are passed on the stack while `objc_msgSend` reads registers.
//!  * `BOOL` is treated as zig `bool`; both AppKit's `bool` (arm64) and
//!    `signed char` (x86_64) return 0/1 in the low byte.

const std = @import("std");
const builtin = @import("builtin");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const IMP = *const fn () callconv(.c) void;

pub const NSUInteger = usize;
pub const NSInteger = isize;

pub const CGPoint = extern struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const CGSize = extern struct {
    width: f64 = 0,
    height: f64 = 0,
};

pub const CGRect = extern struct {
    origin: CGPoint = .{},
    size: CGSize = .{},

    pub fn make(x: f64, y: f64, width: f64, height: f64) CGRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }

    pub fn maxX(self: CGRect) f64 {
        return self.origin.x + self.size.width;
    }

    pub fn maxY(self: CGRect) f64 {
        return self.origin.y + self.size.height;
    }
};

/// NSRect is CGRect on 64-bit macOS, so one struct serves both.
pub const NSRect = CGRect;
pub const NSPoint = CGPoint;
pub const NSSize = CGSize;

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_allocateClassPair(superclass: ?*anyopaque, name: [*:0]const u8, extra: usize) ?*anyopaque;
extern "c" fn objc_registerClassPair(cls: ?*anyopaque) void;
extern "c" fn class_addMethod(cls: ?*anyopaque, name: SEL, imp: IMP, types: [*:0]const u8) bool;

/// Declared with an intentionally useless signature: it is never called
/// directly, only cast to the exact type of each message.
extern "c" fn objc_msgSend() void;

/// Look up a class by name, cached per call site.
pub fn class(comptime name: [*:0]const u8) Class {
    const Cache = struct {
        var value: Class = null;
    };
    if (Cache.value == null) Cache.value = objc_getClass(name);
    return Cache.value;
}

/// Register a selector, cached per call site.
pub fn sel(comptime name: [*:0]const u8) SEL {
    const Cache = struct {
        var value: SEL = null;
    };
    if (Cache.value == null) Cache.value = sel_registerName(name);
    return Cache.value;
}

/// Send a message with exactly the argument types given, returning `Return`.
pub inline fn msgSend(comptime Return: type, receiver: id, selector: SEL, args: anytype) Return {
    const Args = @TypeOf(args);
    const fields = @typeInfo(Args).@"struct".fields;

    const params: []const type = comptime blk: {
        var list: [fields.len + 2]type = undefined;
        list[0] = id;
        list[1] = SEL;
        for (fields, 0..) |field, index| {
            list[index + 2] = field.type;
        }
        const frozen = list;
        break :blk &frozen;
    };

    const Function = @Fn(
        params,
        &@as([fields.len + 2]std.builtin.Type.Fn.Param.Attributes, @splat(.{})),
        Return,
        .{ .@"callconv" = .c },
    );
    const call: *const Function = @ptrCast(&objc_msgSend);
    return @call(.auto, call, .{ receiver, selector } ++ args);
}

pub const Method = struct {
    name: [*:0]const u8,
    imp: IMP,
    types: [*:0]const u8,
};

pub const bool_no_args: [*:0]const u8 = if (builtin.cpu.arch == .aarch64) "B@:" else "c@:";
pub const bool_object_arg: [*:0]const u8 = if (builtin.cpu.arch == .aarch64) "B@:@" else "c@:@";

/// Define a subclass of `superclass` and register the given methods.
pub fn defineClass(
    comptime name: [*:0]const u8,
    superclass: Class,
    methods: []const Method,
) Class {
    const cls = objc_allocateClassPair(superclass, name, 0) orelse return null;
    for (methods) |method| {
        _ = class_addMethod(cls, sel_registerName(method.name), method.imp, method.types);
    }
    objc_registerClassPair(cls);
    return cls;
}
// ---------------------------------------------------------------------------
// CoreGraphics
// ---------------------------------------------------------------------------

pub const CGDirectDisplayID = u32;
pub const CGImageRef = *anyopaque;
pub const CGContextRef = *anyopaque;
pub const CGColorSpaceRef = *anyopaque;

pub extern "c" fn CGMainDisplayID() CGDirectDisplayID;
pub extern "c" fn CGGetActiveDisplayList(
    max_displays: u32,
    displays: [*]CGDirectDisplayID,
    count: *u32,
) c_int;
pub extern "c" fn CGDisplayBounds(display: CGDirectDisplayID) CGRect;
pub extern "c" fn CGDisplayCreateImage(display: CGDirectDisplayID) ?CGImageRef;
pub extern "c" fn CGDisplayCreateImageForRect(
    display: CGDirectDisplayID,
    rect: CGRect,
) ?CGImageRef;
pub extern "c" fn CGImageGetWidth(image: CGImageRef) usize;
pub extern "c" fn CGImageGetHeight(image: CGImageRef) usize;
pub extern "c" fn CGImageRelease(image: CGImageRef) void;
pub extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    space: CGColorSpaceRef,
    bitmap_info: u32,
) ?CGContextRef;
pub extern "c" fn CGBitmapContextGetData(context: CGContextRef) ?*anyopaque;
pub extern "c" fn CGContextClipToRect(context: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextDrawImage(context: CGContextRef, rect: CGRect, image: CGImageRef) void;
pub extern "c" fn CGContextSetInterpolationQuality(context: CGContextRef, quality: c_int) void;
pub extern "c" fn CGContextRelease(context: CGContextRef) void;
pub extern "c" fn CGPreflightScreenCaptureAccess() bool;
pub extern "c" fn CGRequestScreenCaptureAccess() bool;

/// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`: the byte
/// order that matches the core's ARGB8888 pixels on little endian.
pub const bitmap_info_argb8888: u32 = (2) | (2 << 12);

pub const interpolation_none: c_int = 0;

// ---------------------------------------------------------------------------
// AppKit / Foundation constants
// ---------------------------------------------------------------------------

pub const application_activation_policy_regular: NSInteger = 0;
pub const application_activation_policy_accessory: NSInteger = 1;

pub const window_style_borderless: NSUInteger = 0;
pub const backing_store_buffered: NSUInteger = 2;
pub const window_level_screen_saver: NSInteger = 1000;
pub const collection_behavior_can_join_all_spaces: NSUInteger = 1 << 0;
pub const collection_behavior_full_screen_auxiliary: NSUInteger = 1 << 8;

pub const escape_keycode: u16 = 53;
pub const mouse_button_right: NSInteger = 1;
