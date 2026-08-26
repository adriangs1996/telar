//! Exterior-terminal capability negotiation and renderer policy.

const std = @import("std");
const term = @import("../presentation/root.zig").screen;

pub const query_image_id: u32 = 31;
/// Second probe: the same 1x1 image with a zlib-deflated payload. A host that
/// answers OK inflates `o=z` transmissions, which lets the client compress
/// inline image data before base64 instead of shipping raw pixels.
pub const zlib_query_image_id: u32 = 32;
pub const timeout_ns: u64 = 250 * std.time.ns_per_ms;
// "eJxjYGAAAAADAAE=" is the zlib stream for three zero bytes, verified by the
// roundtrip test below; comptime cannot run the flate compressor.
pub const query =
    "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
    "\x1b_Gi=32,s=1,v=1,a=q,t=d,f=24,o=z;eJxjYGAAAAADAAE=\x1b\\" ++
    "\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c";

pub const Support = enum { unknown, unsupported, supported };

pub const TerminalCapabilities = struct {
    kitty_graphics: Support = .unknown,
    kitty_zlib: Support = .unknown,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    mouse_pixels: Support = .unknown,

    pub fn observe(capabilities: *TerminalCapabilities, response: term.Event.TerminalResponse) bool {
        const before = capabilities.*;
        switch (response) {
            .kitty_graphics => |reply| {
                if (reply.image_id == query_image_id)
                    capabilities.kitty_graphics = if (reply.supported) .supported else .unsupported;
                if (reply.image_id == zlib_query_image_id)
                    capabilities.kitty_zlib = if (reply.supported) .supported else .unsupported;
            },
            .window_pixels => |size| {
                capabilities.window_width_px = size.width;
                capabilities.window_height_px = size.height;
            },
            .cell_pixels => |size| {
                capabilities.cell_width_px = size.width;
                capabilities.cell_height_px = size.height;
            },
            .mouse_pixels => |reply| {
                capabilities.mouse_pixels = if (reply.supported) .supported else .unsupported;
            },
            // DA only flushes a multiplexer response path; it does not prove
            // that an earlier APC probe was rejected.
            .primary_device_attributes => {},
        }
        return !std.meta.eql(before, capabilities.*);
    }

    pub fn expire(capabilities: *TerminalCapabilities) bool {
        var changed = false;
        if (capabilities.kitty_graphics == .unknown) {
            capabilities.kitty_graphics = .unsupported;
            changed = true;
        }
        if (capabilities.kitty_zlib == .unknown) {
            capabilities.kitty_zlib = .unsupported;
            changed = true;
        }
        if (capabilities.mouse_pixels == .unknown) {
            capabilities.mouse_pixels = .unsupported;
            changed = true;
        }
        return changed;
    }

    pub fn cellSize(capabilities: *const TerminalCapabilities, cols: u16, rows: u16) struct {
        width: u16,
        height: u16,
    } {
        const width = if (capabilities.cell_width_px != 0)
            capabilities.cell_width_px
        else if (cols != 0)
            capabilities.window_width_px / cols
        else
            0;
        const height = if (capabilities.cell_height_px != 0)
            capabilities.cell_height_px
        else if (rows != 0)
            capabilities.window_height_px / rows
        else
            0;
        return .{
            .width = std.math.cast(u16, width) orelse 0,
            .height = std.math.cast(u16, height) orelse 0,
        };
    }
};

pub const SidebarRendering = enum {
    automatic,
    cells,
    kitty_hybrid,
    kitty_full,

    pub fn parse(name: []const u8) !SidebarRendering {
        if (std.ascii.eqlIgnoreCase(name, "automatic") or std.ascii.eqlIgnoreCase(name, "auto")) return .automatic;
        if (std.ascii.eqlIgnoreCase(name, "cells")) return .cells;
        if (std.ascii.eqlIgnoreCase(name, "kitty-hybrid")) return .kitty_hybrid;
        if (std.ascii.eqlIgnoreCase(name, "kitty-full")) return .kitty_full;
        return error.UnknownSidebarRenderer;
    }

    pub fn resolve(value: SidebarRendering, support: Support) !ResolvedSidebarRendering {
        return switch (value) {
            .automatic => if (support == .supported) .kitty_hybrid else .cells,
            .cells => .cells,
            .kitty_hybrid => if (support == .supported)
                .kitty_hybrid
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
            .kitty_full => if (support == .supported)
                .kitty_full
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
        };
    }
};

pub const ResolvedSidebarRendering = enum { cells, kitty_hybrid, kitty_full };

test "the zlib probe payload inflates to the probe pixel" {
    const encoded = "eJxjYGAAAAADAAE=";
    var compressed: [16]u8 = undefined;
    const compressed_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(compressed[0..compressed_len], encoded);

    var input = std.Io.Reader.fixed(compressed[0..compressed_len]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &window);
    var pixel: [4]u8 = undefined;
    const inflated = try decompress.reader.readSliceShort(&pixel);
    try std.testing.expectEqual(@as(usize, 3), inflated);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, pixel[0..3]);
}

test "the zlib probe resolves independently of the raw probe" {
    var capabilities: TerminalCapabilities = .{};
    try std.testing.expect(capabilities.observe(.{ .kitty_graphics = .{
        .image_id = query_image_id,
        .supported = true,
    } }));
    try std.testing.expectEqual(Support.supported, capabilities.kitty_graphics);
    try std.testing.expectEqual(Support.unknown, capabilities.kitty_zlib);

    try std.testing.expect(capabilities.observe(.{ .kitty_graphics = .{
        .image_id = zlib_query_image_id,
        .supported = false,
    } }));
    try std.testing.expectEqual(Support.unsupported, capabilities.kitty_zlib);

    capabilities.kitty_zlib = .unknown;
    try std.testing.expect(capabilities.expire());
    try std.testing.expectEqual(Support.unsupported, capabilities.kitty_zlib);
}
