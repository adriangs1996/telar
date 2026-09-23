const PaneKey = @import("../pane/PaneKey.zig");
const Identity = @This();

key: PaneKey,
process_id: u32,
session_id: [16]u8,
