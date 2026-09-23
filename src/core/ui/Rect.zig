const Rect = @This();

x: u16 = 0,
y: u16 = 0,
w: u16 = 0,
h: u16 = 0,

// Returns a rectangle with width w and height h that
// is inner to self and is equidistant in both axis
pub fn innerCenter(self: Rect, w: u16, h: u16) Rect {
    const space_x = (self.w - w) / 2;
    const space_y = (self.h - h) / 2;

    const x = self.x + space_x;
    const y = self.y + space_y;

    return .{ .x = x, .y = y, .w = w, .h = h };
}

// `x + w` and `y + h` may exceed maxInt(u16), so every edge sum below is
// computed in u32. Positions past maxInt(u16) are unaddressable; rects
// whose derived origin would land there come back empty.
pub fn contains(self: Rect, x: u16, y: u16) bool {
    return x >= self.x and x < @as(u32, self.x) + self.w and
        y >= self.y and y < @as(u32, self.y) + self.h;
}

/// Shrinks by `margin` on every side, saturating rather than underflowing:
/// a rectangle too small to shrink becomes empty, which draws as nothing.
pub fn inner(self: Rect, margin: u16) Rect {
    const shrink = @as(u32, margin) * 2;
    if (self.w <= shrink or self.h <= shrink) {
        return .{ .x = self.x, .y = self.y };
    }
    return .{
        .x = self.x +| margin,
        .y = self.y +| margin,
        .w = @intCast(self.w - shrink),
        .h = @intCast(self.h - shrink),
    };
}

/// Splits off `cols` from the left. The remainder is the second half.
pub fn splitLeft(self: Rect, cols: u16) [2]Rect {
    const taken = @min(cols, self.w);
    return .{
        .{ .x = self.x, .y = self.y, .w = taken, .h = self.h },
        .{ .x = self.x +| taken, .y = self.y, .w = self.w - taken, .h = self.h },
    };
}

/// Splits off `rows` from the top.
pub fn splitTop(self: Rect, rows: u16) [2]Rect {
    const taken = @min(rows, self.h);
    return .{
        .{ .x = self.x, .y = self.y, .w = self.w, .h = taken },
        .{ .x = self.x, .y = self.y +| taken, .w = self.w, .h = self.h - taken },
    };
}

/// Splits off `rows` from the bottom.
pub fn splitBottom(self: Rect, rows: u16) [2]Rect {
    const taken = @min(rows, self.h);
    return .{
        .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h - taken },
        .{ .x = self.x, .y = self.y +| (self.h - taken), .w = self.w, .h = taken },
    };
}

/// The overlap of two rectangles, empty if they do not touch.
///
/// Nested clips intersect rather than replace: a widget that pushes a clip
/// bigger than its parent's would otherwise draw straight out of the box
/// it was handed, which is the escape hatch clipping exists to close.
pub fn intersect(self: Rect, b: Rect) Rect {
    const x = @max(self.x, b.x);
    const y = @max(self.y, b.y);
    const right = @min(@as(u32, self.x) + self.w, @as(u32, b.x) + b.w);
    const bottom = @min(@as(u32, self.y) + self.h, @as(u32, b.y) + b.h);
    if (right <= x or bottom <= y) {
        return .{ .x = x, .y = y };
    }
    // The overlap starts at a u16 corner and each edge is bounded by one
    // input's width, so the differences fit u16 again.
    return .{
        .x = x,
        .y = y,
        .w = @intCast(right - x),
        .h = @intCast(bottom - y),
    };
}

pub fn isEmpty(self: Rect) bool {
    return self.w == 0 or self.h == 0;
}

pub fn row(self: Rect, index: u16) Rect {
    if (index >= self.h) {
        return .{ .x = self.x, .y = self.y };
    }
    return .{ .x = self.x, .y = self.y +| index, .w = self.w, .h = 1 };
}
