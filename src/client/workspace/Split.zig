const Split = @This();
const source_namespace = @import("layout_support.zig");
axis: source_namespace.Axis,
ratio: u16 = source_namespace.default_split_ratio,
first: source_namespace.NodeIndex,
second: source_namespace.NodeIndex,
