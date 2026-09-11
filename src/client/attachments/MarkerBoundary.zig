const CursorType = @import("telar-core").Cursor;
const types = @import("types.zig");
const MarkerBoundary = @This();

ordinal: u16,
cursor: CursorType,
deletion: types.MarkerDeletion,
