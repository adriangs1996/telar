//! One ranked path copied out of an index, so a reply outlives it.

const core = @import("telar-core");

// SAFETY: PathQuery.copy copies the path before publishing the match; results reads only path_len bytes.
path: [core.max_path_match_bytes]u8 = undefined,
path_len: u16 = 0,
kind: core.PathKind = .file,
// SAFETY: PathQuery.copy records position_count only after a successful match has filled those positions.
positions: [core.max_path_query_bytes]u16 = undefined,
position_count: u8 = 0,
