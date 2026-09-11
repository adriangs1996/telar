const Point = @import("Point.zig");
const copy_mode = @import("copy_mode.zig");
const View = @This();

cursor: Point,
pointer: bool = false,
anchor: ?Point,
linewise: bool,

pub fn selected(view: View, x: u16, y: u32) bool {
    const anchor = view.anchor orelse return false;
    if (view.linewise) {
        const first = @min(anchor.y, view.cursor.y);
        const last = @max(anchor.y, view.cursor.y);
        return y >= first and y <= last;
    }
    const point = Point{ .x = x, .y = y };
    const first, const last = if (copy_mode.less(view.cursor, anchor))
        .{ view.cursor, anchor }
    else
        .{ anchor, view.cursor };
    return !copy_mode.less(point, first) and !copy_mode.less(last, point);
}
