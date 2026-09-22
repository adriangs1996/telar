const core = @import("telar-core");
const OwnedHistoryQuery = @This();

/// The palette query comes from the prompt field, which is bounded by
/// the tab-label capacity; the caps keep queue messages small.
pub const max_query_bytes = 128;
pub const max_scope_bytes = 256;

request_id: core.RequestId,
query: [max_query_bytes]u8 = undefined,
query_len: u8 = 0,
scope: core.HistoryScope = .global,
scope_value: [max_scope_bytes]u8 = undefined,
scope_value_len: u16 = 0,
pane_id: core.PaneId = .invalid,
author: core.HistoryAuthorFilter = .all,
match: core.HistoryMatch = .fts,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,

pub fn view(value: *const OwnedHistoryQuery) core.QueryHistory {
    return .{
        .request_id = value.request_id,
        .query = value.query[0..value.query_len],
        .scope = value.scope,
        .scope_value = value.scope_value[0..value.scope_value_len],
        .pane_id = value.pane_id,
        .failed_only = false,
        .author = value.author,
        .match = value.match,
        .distinct = false,
        .limit = value.limit,
        .offset = value.offset,
        .snapshot_id = value.snapshot_id,
        .entry_id = value.entry_id,
    };
}
