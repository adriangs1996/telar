const PaneKeyType = @import("../pane/PaneKey.zig");
const Identity = @This();

key: PaneKeyType,
process_id: u32,
session_id: [16]u8,
