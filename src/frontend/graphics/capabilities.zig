//! Exterior-terminal probe constants and renderer policy.

const std = @import("std");

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

pub const SidebarRendering = enum {
    automatic,
    cells,
    kitty_hybrid,
    kitty_full,

    pub fn parse(name: []const u8) !SidebarRendering {
        if (std.ascii.eqlIgnoreCase(name, "automatic") or std.ascii.eqlIgnoreCase(name, "auto")) {
            return .automatic;
        }
        if (std.ascii.eqlIgnoreCase(name, "cells")) {
            return .cells;
        }
        if (std.ascii.eqlIgnoreCase(name, "kitty-hybrid")) {
            return .kitty_hybrid;
        }
        if (std.ascii.eqlIgnoreCase(name, "kitty-full")) {
            return .kitty_full;
        }
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
