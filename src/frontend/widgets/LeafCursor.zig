//! Where the next leaf of a cell row starts, and at which fitted level.
const cellgrid = @import("cellgrid");
const data = @import("model");
const LeafCursor = @This();

area: cellgrid.Rect,
x: u16,
level: data.FitLevel = .full,
