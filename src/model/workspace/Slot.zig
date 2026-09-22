const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const Slot = @This();

parent: ?layout_support.NodeIndex = null,
node: layout_support.Node = .empty,
/// Meaningful for leaves only: how the pane is shown.
surface: core.PaneSurface = .terminal,
