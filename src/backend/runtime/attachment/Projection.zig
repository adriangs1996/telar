const BufferType = @import("telar-core").Buffer;
const CursorType = @import("telar-core").Cursor;
const ScrollType = @import("telar-core").Scroll;
const Projection = @This();

buffer: *const BufferType,
damaged_rows: []const bool,
cursor: CursorType,
scroll: ScrollType,
