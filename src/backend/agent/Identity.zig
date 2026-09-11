const Identity = @This();
const source_namespace = @import("types.zig");
key: source_namespace.PaneKey,
process_id: u32,
session_id: [16]u8,
