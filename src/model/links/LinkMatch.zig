//! An owned URI and its cell interval in absolute pane coordinates.
const data = @import("../model.zig");
const Position = @import("Position.zig");

target: data.LinkTarget,
start: Position,
/// Exclusive end, possibly on a later soft-wrapped row.
end: Position,
/// OSC 8 identity local to this pane metadata replacement.
link_index: ?u16 = null,
