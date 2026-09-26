//! One ranked path copied out of an index, so a reply outlives it.

const core = @import("telar-core");
const FoundPath = @This();

path: [core.max_path_match_bytes]u8 = undefined,
path_len: u16 = 0,
kind: core.PathKind = .file,
positions: [core.max_path_query_bytes]u16 = undefined,
position_count: u8 = 0,
