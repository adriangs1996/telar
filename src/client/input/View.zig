const View = @This();
const Point = @import("Point.zig");
const source_namespace = @import("copy_mode.zig");
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
    const first, const last = if (source_namespace.less(view.cursor, anchor))
        .{ view.cursor, anchor }
    else
        .{ anchor, view.cursor };
    return !source_namespace.less(point, first) and !source_namespace.less(last, point);
}
