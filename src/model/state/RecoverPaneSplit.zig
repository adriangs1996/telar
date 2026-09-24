const cellgrid = @import("cellgrid");
const data = @import("../model.zig");
const RecoverPaneSplit = @This();

split: data.PaneSplit,
area: cellgrid.Rect,
