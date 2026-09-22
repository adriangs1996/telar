//! One clipped label written at a column of a single-row area.
const core = @import("telar-core");
const InlineLabel = @This();

area: core.Rect,
x: u16,
text: []const u8,
style: core.Style,
