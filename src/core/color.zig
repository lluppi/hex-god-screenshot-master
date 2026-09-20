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

/// sRGB byte -> linear light. Screens encode roughly `v^2.2`, so averaging two
/// encoded values is not averaging two amounts of light: a half-covered white
/// edge pixel blended at 50% in encoded space emits about 21% of the light it
/// should, which is why thin bright curves bead and look stair-stepped however
/// exact the coverage is.
const to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*slot, i| {
        const v: f64 = @as(f64, @floatFromInt(i)) / 255.0;
        slot.* = @floatCast(if (v <= 0.04045)
            v / 12.92
        else
            std.math.pow(f64, (v + 0.055) / 1.055, 2.4));
    }
    break :blk table;
};

/// Linear light -> the nearest sRGB byte, by binary search over `to_linear`, so
/// the encode is exactly the inverse of the decode and needs no second table.
fn fromLinear(value: f32) u32 {
    const light = std.math.clamp(value, 0, 1);
    var low: usize = 0;
    var high: usize = 255;
    while (low < high) {
        const mid = (low + high + 1) / 2;
        if (to_linear[mid] <= light) low = mid else high = mid - 1;
    }
    if (low < 255 and light - to_linear[low] > to_linear[low + 1] - light) return @intCast(low + 1);
    return @intCast(low);
}

/// `over`, but the colour mix happens in linear light instead of in sRGB codes.
/// Only anti-aliased glyph edges go through this: light text on a dark plate is
/// where the gamma error is visible, and it costs table lookups and a search.
pub fn overLinear(dst: u32, src: u32) u32 {
    const sa: u32 = (src >> 24) & 0xff;
    if (sa == 0) return dst;
    if (sa == 255) return src;
    const da: u32 = (dst >> 24) & 0xff;

    const s_alpha: f32 = @as(f32, @floatFromInt(sa)) / 255.0;
    const d_alpha: f32 = @as(f32, @floatFromInt(da)) / 255.0;
    const d_keep = d_alpha * (1 - s_alpha);
    const r_alpha = s_alpha + d_keep;

    // Un-premultiply both sides so their own colours are decoded, mix in
    // linear light, then re-premultiply by the result alpha.
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const s: u32 = @min(255, (((src >> shift) & 0xff) * 255 + sa / 2) / sa);
        const d: u32 = if (da == 0) 0 else @min(255, (((dst >> shift) & 0xff) * 255 + da / 2) / da);
        const mixed = (to_linear[s] * s_alpha + to_linear[d] * d_keep) / r_alpha;
        const encoded: f32 = @floatFromInt(fromLinear(mixed));
        out |= @as(u32, @intFromFloat(@round(encoded * r_alpha))) << shift;
    }

    const a: u32 = @intFromFloat(@round(r_alpha * 255));
    return (a << 24) | out;
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

/// Multiply each channel towards black, used for the full-screen dim while the
/// instrument is active. 236/256 keeps the desktop legible while making the
/// undimmed selection read as a distinct optical channel.
pub fn dimPixel(pixel: u32, numerator: u32) u32 {
    const a: u32 = (pixel >> 24) & 0xff;
    const r = (((pixel >> 16) & 0xff) * numerator) >> 8;
    const g = (((pixel >> 8) & 0xff) * numerator) >> 8;
    const b = ((pixel & 0xff) * numerator) >> 8;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

pub const dim_numerator: u32 = 236;
