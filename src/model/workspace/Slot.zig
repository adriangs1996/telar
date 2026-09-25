const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const Split = @import("Split.zig");
const Slot = @This();

parent: ?layout_support.NodeIndex = null,
node: LayoutNode = .empty,
/// Meaningful for leaves only: how the pane is shown.
surface: core.PaneSurface = .terminal,

const LayoutNode = union(enum) {
    empty,
    leaf: core.PaneId,
    split: Split,
};
