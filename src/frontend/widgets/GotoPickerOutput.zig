const RectType = @import("telar-core").Rect;
const CursorType = @import("Cursor.zig");
const Output = @This();

area: RectType,
cursor: ?CursorType,
