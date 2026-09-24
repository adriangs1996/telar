//! PNG decoding for Ghostty's media terminal. All Wuffs allocations use the
//! caller's quota-accounted allocator, including decoder and work buffers.

const core = @import("telar-core");
const ParkingMutex = @import("ParkingMutex.zig");
const vt = @import("ghostty-vt");
const std = @import("std");
const imaging = @import("imaging");
const GraphicsBudget = @import("GraphicsBudget.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");

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

const fixture = @embedFile("testdata/rgba.png");

fn expectDecoded(allocator: std.mem.Allocator) !void {
    const image = try decode(allocator, fixture);
    defer allocator.free(image.data);

    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data);
}

test "PNG decoder releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectDecoded, .{});
}

test "PNG decoder rejects malformed and truncated input" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, "not a PNG"));
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, fixture[0 .. fixture.len / 2]));
}

test "PNG decoder normalizes RGB and grayscale and preserves straight alpha" {
    const cases = .{
        .{ @embedFile("testdata/rgb.png"), [_]u8{ 1, 2, 3, 255 } },
        .{ @embedFile("testdata/gray.png"), [_]u8{ 127, 127, 127, 255 } },
        .{ @embedFile("testdata/alpha.png"), [_]u8{ 1, 2, 3, 128 } },
    };
    inline for (cases) |case| {
        const image = try decode(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(image.data);
        const expected = case[1];
        try std.testing.expectEqualSlices(u8, &expected, image.data);
    }
}

test "PNG decoder charges workspace and rejects oversized pixels before allocation" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    var budget = GraphicsBudget.init(1024 * 1024);
    var tracked = PaneMediaAllocator.init(std.testing.allocator, &budget, budget.limit);

    try expectDecoded(tracked.allocator());
    try std.testing.expectEqual(@as(usize, 0), budget.used);

    // A valid IHDR declares almost 4 GiB of RGBA pixels. It is refused from
    // the header, before Wuffs requests anything from the quota allocator.
    var oversized = fixture.*;
    std.mem.writeInt(u32, oversized[16..20], 32768, .big);
    std.mem.writeInt(u32, oversized[20..24], 32767, .big);
    std.mem.writeInt(u32, oversized[29..33], std.hash.Crc32.hash(oversized[12..29]), .big);
    try std.testing.expectError(error.OutOfMemory, decode(tracked.allocator(), &oversized));
    try std.testing.expectEqual(@as(usize, 0), budget.used);

    tracked.limit = 1;
    try std.testing.expectError(error.OutOfMemory, decode(tracked.allocator(), fixture));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
