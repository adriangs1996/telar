const Slot = @This();
const source_namespace = @import("layout_support.zig");
parent: ?source_namespace.NodeIndex = null,
node: source_namespace.Node = .empty,
