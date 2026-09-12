const core = @import("telar-core");

pane_id: core.PaneId = .invalid,
generation: u64 = 0,
cursor: core.Cursor = .{},
