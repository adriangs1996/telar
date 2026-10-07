//! One match of the path picker's page; its path lives in the page bytes.

const core = @import("telar-core");

offset: u16 = 0,
len: u16 = 0,
kind: core.PathKind = .file,
// SAFETY: PathPickerState copies the positions before publishing the match; highlighting reads only position_count entries.
positions: [core.max_path_query_bytes]u16 = undefined,
position_count: u8 = 0,
