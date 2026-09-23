const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const Output = @This();

area: core.Rect,
cursor: ?Cursor,
