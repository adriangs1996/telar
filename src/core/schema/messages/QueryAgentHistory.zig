const id = @import("../id.zig");

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
view_generation: u64,
cursor: []const u8 = "",
anchor: []const u8 = "",
anchor_turn: []const u8 = "",
direction: @import("../../agent_history.zig").Direction = .older,
