const cellgrid = @import("cellgrid");
const Cursor = @import("Cursor.zig");
const Output = @This();

area: cellgrid.Rect,
cursor: ?Cursor,
