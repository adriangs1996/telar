const core = @import("telar-core");
const Split = @import("../workspace/Split.zig");

pub const LayoutNode = union(enum) {
    empty,
    leaf: core.PaneId,
    split: Split,
};
