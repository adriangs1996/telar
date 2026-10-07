//! PNG decoding for Ghostty's media terminal. All Wuffs allocations use the
//! caller's quota-accounted allocator, including decoder and work buffers.

const core = @import("telar-core");
const ParkingMutex = @import("ParkingMutex.zig");
const vt = @import("ghostty-vt");
const std = @import("std");
const imaging = @import("imaging");

var install_mutex: ParkingMutex = .{};
var installed = false;

/// Installs the process-wide callback before a media terminal can consume
/// output. Later pane creation never rewrites a pointer actors may be reading.
/// Example: `png.install();`.
pub fn install() void {
    install_mutex.lock();
    defer install_mutex.unlock();

    if (installed) {
        return;
    }

    vt.sys.decode_png = decode;
    installed = true;
}

/// Decodes through `imaging`, which rejects dimensions beyond one screen of
/// RGBA before Wuffs allocates. A PNG too large to hold is out of memory to
/// the child, as it was when the quota refused the allocation.
fn decode(allocator: std.mem.Allocator, bytes: []const u8) vt.sys.DecodeError!vt.sys.Image {
    const image = imaging.png.decode(allocator, bytes, .{
        .max_side = std.math.maxInt(u32),
        .max_pixels = max_pixels,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.PngTooLarge => return error.OutOfMemory,
        error.NotPng, error.InvalidPngData => return error.InvalidData,
    };

    return .{
        .width = image.width,
        .height = image.height,
        .data = image.pixels,
    };
}

/// One screen of RGBA pixels.
const max_pixels: u32 = @intCast(core.max_image_bytes_per_screen / rgba_bytes);
const rgba_bytes = 4;
