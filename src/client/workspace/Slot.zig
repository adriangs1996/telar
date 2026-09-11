const layout_support = @import("layout_support.zig");
const Slot = @This();

parent: ?layout_support.NodeIndex = null,
node: layout_support.Node = .empty,
