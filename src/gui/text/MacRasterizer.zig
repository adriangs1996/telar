//! Owns a CoreText face and an alpha context borrowing the atlas page.
//! Call only on the owning atlas thread; cached glyphs bypass this port.
const builtin = @import("builtin");
const Options = @import("../native/GlyphRasterizerOptions.zig").GlyphRasterizerOptions;
const Glyph = @import("../native/GlyphRaster.zig").GlyphRaster;
const Rasterizer = @This();

handle: *anyopaque,

extern fn telar_glyph_rasterizer_create(options: *const Options) ?*anyopaque;
extern fn telar_glyph_rasterizer_destroy(handle: *anyopaque) void;
extern fn telar_glyph_rasterizer_select(handle: *anyopaque, pixel_height: u32) c_int;
extern fn telar_glyph_rasterizer_measure(handle: *anyopaque, glyph: *Glyph) c_int;
extern fn telar_glyph_rasterizer_draw(handle: *anyopaque, glyph: *const Glyph) void;

/// The face bytes and page must remain alive through deinit.
/// Example: `var rasterizer = try MacRasterizer.init(options);`
pub fn init(options: Options) !Rasterizer {
    if (builtin.os.tag != .macos) {
        return error.UnsupportedPlatform;
    }

    return .{ .handle = telar_glyph_rasterizer_create(&options) orelse return error.NativeRasterizerInitFailed };
}

pub fn deinit(self: *Rasterizer) void {
    if (builtin.os.tag == .macos) {
        telar_glyph_rasterizer_destroy(self.handle);
    }
}

/// Selects sized regular/italic faces without changing shaping or cell metrics.
/// Example: `try rasterizer.select(36);`
pub fn select(self: *Rasterizer, pixel_height: u16) !void {
    if (builtin.os.tag != .macos) {
        return error.UnsupportedPlatform;
    }

    if (telar_glyph_rasterizer_select(self.handle, pixel_height) != 0) {
        return error.NativeRasterizerSizeFailed;
    }
}

/// Includes smoothing/stroke overhang before the atlas reserves its rectangle.
/// Example: `const glyph = try rasterizer.measure(.{ .index = id, .style = 1 });`
pub fn measure(self: *Rasterizer, request: Glyph) !Glyph {
    if (builtin.os.tag != .macos) {
        return error.UnsupportedPlatform;
    }

    var glyph = request;
    if (telar_glyph_rasterizer_measure(self.handle, &glyph) != 0) {
        return error.NativeGlyphMeasureFailed;
    }

    return glyph;
}

/// Draws into the reserved page rectangle; no temporary bitmap is allocated.
/// Example: `rasterizer.draw(glyph);`
pub fn draw(self: *Rasterizer, glyph: Glyph) void {
    if (builtin.os.tag == .macos) {
        telar_glyph_rasterizer_draw(self.handle, &glyph);
    }
}
