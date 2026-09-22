const agent_history = @import("../../agent_history.zig");
const id = @import("../id.zig");

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
view_generation: u64,
cursor: []const u8 = "",
anchor: []const u8 = "",
anchor_turn: []const u8 = "",
direction: agent_history.Direction = .older,
