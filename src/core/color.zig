//! Colours are carried around as premultiplied ARGB8888 `u32`, which is exactly
//! the layout of a `WL_SHM_FORMAT_ARGB8888` buffer on little endian machines
//! (bytes B, G, R, A) and of a CoreGraphics `kCGImageAlphaPremultipliedFirst`
//! bitmap with `kCGBitmapByteOrder32Little`. Screens are opaque so alpha is 255
//! for anything sampled from the screen.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn argb(rgb: Rgb, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

pub fn solid(rgb: Rgb) u32 {
    return argb(rgb, 255);
}

pub fn rgbOf(pixel: u32) Rgb {
    return .{
        .r = @intCast((pixel >> 16) & 0xff),
        .g = @intCast((pixel >> 8) & 0xff),
        .b = @intCast(pixel & 0xff),
    };
}

/// Black at the given opacity, premultiplied (the only translucent colour the
/// badges need).
pub fn black(alpha: u8) u32 {
    return @as(u32, alpha) << 24;
}

/// Scale a premultiplied pixel's alpha (and therefore its components) by a
/// coverage fraction, for anti-aliased edges. Premultiplied means this needs no
/// unpremultiply/repremultiply round trip: every channel, alpha included, is
/// simply multiplied by the same factor.
pub fn withCoverage(pixel: u32, coverage: f64) u32 {
    if (coverage <= 0) return 0;
    if (coverage >= 1) return pixel;
    const a: u32 = (pixel >> 24) & 0xff;
    const scaled: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(a)) * coverage));
    if (scaled == 0) return 0;
    const red = (((pixel >> 16) & 0xff) * scaled) / a;
    const green = (((pixel >> 8) & 0xff) * scaled) / a;
    const blue = ((pixel & 0xff) * scaled) / a;
    return (scaled << 24) | (red << 16) | (green << 8) | blue;
}

/// `#RRGGBB`, uppercase, exactly like the mac app printed.
pub fn hexString(rgb: Rgb) [7]u8 {
    var out: [7]u8 = undefined;
    out[0] = '#';
    const digits = "0123456789ABCDEF";
    out[1] = digits[rgb.r >> 4];
    out[2] = digits[rgb.r & 0x0f];
    out[3] = digits[rgb.g >> 4];
    out[4] = digits[rgb.g & 0x0f];
    out[5] = digits[rgb.b >> 4];
    out[6] = digits[rgb.b & 0x0f];
    return out;
}

/// src-over compositing for premultiplied ARGB8888.
pub fn over(dst: u32, src: u32) u32 {
    const sa: u32 = (src >> 24) & 0xff;
    if (sa == 0) return dst;
    if (sa == 255) return src;
    const inv: u32 = 255 - sa;
    const rb = ((src & 0x00ff00ff) + ((((dst & 0x00ff00ff) * inv + 0x00800080) >> 8))) & 0x00ff00ff;
    const ga = (((src >> 8) & 0x00ff00ff) + ((((dst >> 8) & 0x00ff00ff) * inv + 0x00800080) >> 8)) & 0x00ff00ff;
    const a = sa + ((dst >> 24) * inv + 128) / 255;
    return (a << 24) | (ga << 8) | rb;
}

/// Multiply each channel towards black, used for the full screen dim while the
/// overlay is up. 246/256 == 0.9609, close enough to the mac app's 4% black.
pub fn dimPixel(pixel: u32, numerator: u32) u32 {
    const a: u32 = (pixel >> 24) & 0xff;
    const r = (((pixel >> 16) & 0xff) * numerator) >> 8;
    const g = (((pixel >> 8) & 0xff) * numerator) >> 8;
    const b = ((pixel & 0xff) * numerator) >> 8;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

pub const dim_numerator: u32 = 246;
