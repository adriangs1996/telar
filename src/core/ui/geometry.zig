//! Rectangles, and nothing else.
//!
//! Layout here is arithmetic: no tree, no constraint solver, no state. That is
//! worth defending, because it means a layout can be unit tested without a
//! terminal, without a buffer, and without a frame.

const std = @import("std");

pub const Point = @import("Point.zig");

pub const Rect = @import("Rect.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "rectangle arithmetic survives coordinates near the u16 limit" {
    // x + w exceeds maxInt(u16). Doing the sums in u16 panics in safe builds
    // and wraps in fast builds, where a wrapped edge makes `contains` reject
    // every point and `intersect` return garbage.
    const r: Rect = .{ .x = 60000, .y = 0, .w = 10000, .h = 2 };
    try testing.expect(r.contains(65000, 0));
    try testing.expect(r.contains(65535, 1));
    try testing.expect(!r.contains(500, 0));

    const clipped = r.intersect(.{ .x = 0, .y = 0, .w = 65535, .h = 65535 });
    try testing.expectEqual(@as(u16, 60000), clipped.x);
    try testing.expectEqual(@as(u16, 5535), clipped.w);

    const halves = r.splitLeft(8000);
    try testing.expectEqual(@as(u16, 8000), halves[0].w);
    try testing.expectEqual(@as(u16, 2000), halves[1].w);
}

test "rectangles split without overlapping or losing columns" {
    const full: Rect = .{ .w = 80, .h = 24 };
    const left, const right = full.splitLeft(20);

    try testing.expectEqual(@as(u16, 20), left.w);
    try testing.expectEqual(@as(u16, 60), right.w);
    try testing.expectEqual(left.x + left.w, right.x);
    try testing.expectEqual(full.w, left.w + right.w);
}

test "splitting past the edge yields an empty remainder rather than wrapping" {
    // Underflowing u16 here would produce a rectangle 65000 columns wide, and
    // every write into it would look like memory corruption.
    const narrow: Rect = .{ .w = 10, .h = 3 };
    const taken, const rest = narrow.splitLeft(40);
    try testing.expectEqual(@as(u16, 10), taken.w);
    try testing.expectEqual(@as(u16, 0), rest.w);
}
