const core = @import("telar-core");

cursor: []const u8 = "",
anchor: []const u8 = "",
anchor_turn: []const u8 = "",
direction: core.agent_history.Direction = .older,
