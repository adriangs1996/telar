const core = @import("telar-core");
const Pane = @This();

id: core.PaneId,
attachment_generation: u64,
cols: u16,
rows: u16,
