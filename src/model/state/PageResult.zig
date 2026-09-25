const core = @import("telar-core");
const PageResult = @This();

request_id: u64,
entries: []const core.HistoryEntry,
snapshot_id: u64,
has_more: bool,
now_ms: i64,
/// Minutes east of UTC where the client runs, read when the reply landed.
utc_offset_min: i16 = 0,
