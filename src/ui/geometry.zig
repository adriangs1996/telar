//! Rectangles, and nothing else.
//!
//! Layout here is arithmetic: no tree, no constraint solver, no state. That is
//! worth defending, because it means a layout can be unit tested without a
//! terminal, without a buffer, and without a frame.

const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(r: Rect, x: u16, y: u16) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }

    /// Shrinks by `margin` on every side, saturating rather than underflowing:
    /// a rectangle too small to shrink becomes empty, which draws as nothing.
    pub fn inner(r: Rect, margin: u16) Rect {
        if (r.w <= margin * 2 or r.h <= margin * 2) return .{ .x = r.x, .y = r.y };
        return .{
            .x = r.x + margin,
            .y = r.y + margin,
            .w = r.w - margin * 2,
            .h = r.h - margin * 2,
        };
    }

    /// Splits off `cols` from the left. The remainder is the second half.
    pub fn splitLeft(r: Rect, cols: u16) [2]Rect {
        const taken = @min(cols, r.w);
        return .{
            .{ .x = r.x, .y = r.y, .w = taken, .h = r.h },
            .{ .x = r.x + taken, .y = r.y, .w = r.w - taken, .h = r.h },
        };
    }

    /// Splits off `rows` from the top.
    pub fn splitTop(r: Rect, rows: u16) [2]Rect {
        const taken = @min(rows, r.h);
        return .{
            .{ .x = r.x, .y = r.y, .w = r.w, .h = taken },
            .{ .x = r.x, .y = r.y + taken, .w = r.w, .h = r.h - taken },
        };
    }

    /// Splits off `rows` from the bottom.
    pub fn splitBottom(r: Rect, rows: u16) [2]Rect {
        const taken = @min(rows, r.h);
        return .{
            .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - taken },
            .{ .x = r.x, .y = r.y + r.h - taken, .w = r.w, .h = taken },
        };
    }

    /// The overlap of two rectangles, empty if they do not touch.
    ///
    /// Nested clips intersect rather than replace: a widget that pushes a clip
    /// bigger than its parent's would otherwise draw straight out of the box
    /// it was handed, which is the escape hatch clipping exists to close.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const right = @min(a.x + a.w, b.x + b.w);
        const bottom = @min(a.y + a.h, b.y + b.h);
        if (right <= x or bottom <= y) return .{ .x = x, .y = y };
        return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    }

    pub fn isEmpty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }

    pub fn row(r: Rect, index: u16) Rect {
        if (index >= r.h) return .{ .x = r.x, .y = r.y };
        return .{ .x = r.x, .y = r.y + index, .w = r.w, .h = 1 };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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
