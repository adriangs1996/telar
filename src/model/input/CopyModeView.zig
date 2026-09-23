const Point = @import("Point.zig");
const copy_mode = @import("copy_mode.zig");
const View = @This();

cursor: Point,
pointer: bool = false,
anchor: ?Point,
linewise: bool,

pub fn selected(self: View, x: u16, y: u32) bool {
    const anchor = self.anchor orelse return false;
    if (self.linewise) {
        const first = @min(anchor.y, self.cursor.y);
        const last = @max(anchor.y, self.cursor.y);
        return y >= first and y <= last;
    }
    const point = Point{
        .x = x,
        .y = y,
    };
    const first, const last = if (copy_mode.less(self.cursor, anchor))
        .{
            self.cursor,
            anchor,
        }
    else
        .{
            anchor,
            self.cursor,
        };
    return !copy_mode.less(point, first) and !copy_mode.less(last, point);
}
