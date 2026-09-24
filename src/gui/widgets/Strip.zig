const cellgrid = @import("cellgrid");
const Strip = @This();

area: cellgrid.Rect,
used: u16 = 0,

/// Consumes a bounded section without allowing labels to overlap.
/// Example: `const target = strip.take(12);`
pub fn take(self: *Strip, requested: u16) cellgrid.Rect {
    const width = @min(requested, self.area.w -| self.used);
    const result: cellgrid.Rect = .{ .x = self.area.x +| self.used, .y = self.area.y, .w = width, .h = self.area.h };
    self.used += width;
    return result;
}

pub fn remaining(self: *const Strip) u16 {
    return self.area.w -| self.used;
}
