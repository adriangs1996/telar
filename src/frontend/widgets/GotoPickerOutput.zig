const core = @import("telar-core");
const CursorType = @import("Cursor.zig");
const Output = @This();

area: core.Rect,
cursor: ?CursorType,
