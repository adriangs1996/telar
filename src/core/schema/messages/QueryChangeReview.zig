const id = @import("../id.zig");
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
edition_id: u64 = 0,
session: []const u8 = "",
