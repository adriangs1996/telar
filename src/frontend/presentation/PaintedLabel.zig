const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const PaintedLabel = @This();

buffer: *const BufferType,
area: RectType,
selected: bool,
