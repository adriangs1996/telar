const data = @import("../model.zig");
const core = @import("telar-core");
const RecoverPaneSplit = @This();

split: data.PaneSplit,
area: core.Rect,
