const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const RowTarget = @This();

buffer: *BufferType,
area: RectType,
y: u16,
