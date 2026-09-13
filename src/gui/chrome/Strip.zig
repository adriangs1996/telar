const core = @import("telar-core");
const Strip = @This();

area: core.Rect,
used: u16 = 0,

/// Consumes a bounded section without allowing labels to overlap.
/// Example: `const target = strip.take(12);`
pub fn take(strip: *Strip, requested: u16) core.Rect {
    const width = @min(requested, strip.area.w -| strip.used);
    const result: core.Rect = .{ .x = strip.area.x +| strip.used, .y = strip.area.y, .w = width, .h = strip.area.h };
    strip.used += width;
    return result;
}

pub fn remaining(strip: *const Strip) u16 {
    return strip.area.w -| strip.used;
}
