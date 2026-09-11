const layout_support = @import("layout_support.zig");
const Split = @This();

axis: layout_support.Axis,
ratio: u16 = layout_support.default_split_ratio,
first: layout_support.NodeIndex,
second: layout_support.NodeIndex,
