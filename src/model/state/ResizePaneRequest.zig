const core = @import("telar-core");
const layout_support = @import("../workspace/layout_support.zig");
const ResizePaneRequest = @This();

direction: layout_support.Direction,
area: core.Rect,
