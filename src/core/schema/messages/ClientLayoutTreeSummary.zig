const id = @import("../id.zig");
const ClientLayoutTreeSummary = @This();

node_count: usize,
focused_pane: id.PaneId,
