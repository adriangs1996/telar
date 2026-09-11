const OwnedHistoryQuery = @This();
const source_namespace = @import("outbox_support.zig");
/// The palette query comes from the prompt field, which is bounded by
/// the tab-label capacity; the caps keep queue messages small.
pub const max_query_bytes = 128;
pub const max_scope_bytes = 256;

request_id: source_namespace.schema.RequestId,
query: [max_query_bytes]u8 = undefined,
query_len: u8 = 0,
scope: source_namespace.schema.HistoryScope = .global,
scope_value: [max_scope_bytes]u8 = undefined,
scope_value_len: u16 = 0,
pane_id: source_namespace.schema.PaneId = .invalid,
author: source_namespace.schema.HistoryAuthorFilter = .all,
match: source_namespace.schema.HistoryMatch = .fts,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,

pub fn view(value: *const OwnedHistoryQuery) source_namespace.schema.QueryHistory {
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
