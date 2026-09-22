const core = @import("telar-core");
const PaintedLabel = @This();

buffer: *const core.Buffer,
area: core.Rect,
selected: bool,
