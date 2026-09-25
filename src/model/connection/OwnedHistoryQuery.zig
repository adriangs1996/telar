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
failed_only: bool = false,
author: core.HistoryAuthorFilter = .all,
match: core.HistoryMatch = .fts,
limit: u16,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,

pub fn view(self: *const OwnedHistoryQuery) core.QueryHistory {
    return .{
        .request_id = self.request_id,
        .query = self.query[0..self.query_len],
        .scope = self.scope,
        .scope_value = self.scope_value[0..self.scope_value_len],
        .pane_id = self.pane_id,
        .failed_only = self.failed_only,
        .author = self.author,
        .match = self.match,
        .distinct = false,
        .limit = self.limit,
        .offset = self.offset,
        .snapshot_id = self.snapshot_id,
        .entry_id = self.entry_id,
    };
}
