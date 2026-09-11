const PaneKeyType = @import("../../../pane/PaneKey.zig");
const Started = @This();

pane: PaneKeyType = undefined,
session_id: [16]u8 = undefined,
query_matches: bool = false,
