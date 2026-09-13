//! An owned URI and its cell interval on one absolute pane row.
const Position = @import("Position.zig");

target: @import("LinkTarget.zig"),
start: Position,
/// Exclusive column on the same absolute row, including wide-cell continuations.
end: Position,
