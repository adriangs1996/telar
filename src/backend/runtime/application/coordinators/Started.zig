const Started = @This();
const pane_mod = @import("../../../pane/root.zig");
pane: pane_mod.PaneKey = undefined,
session_id: [16]u8 = undefined,
query_matches: bool = false,
