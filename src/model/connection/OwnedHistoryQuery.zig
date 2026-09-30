const core = @import("telar-core");
const OwnedHistoryQuery = @This();

/// The palette query comes from the prompt field, so it holds what the
/// field holds and keeps queue messages small.
pub const max_query_bytes = core.max_tab_label_bytes;
/// A workspace path or a working directory; it travels in the queued
/// message's payload slot, not in the message.
pub const max_scope_bytes = core.max_cwd_bytes;

request_id: core.RequestId,
query: [max_query_bytes]u8 = undefined,
query_len: u8 = 0,
scope: core.HistoryScope = .global,
/// Borrowed until the outbox queues the query, which copies it into the
/// message's payload slot (`ownScope`).
scope_value: []const u8 = "",
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
        .scope_value = self.scope_value,
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

/// Copies the scope path into the queued message's payload so it outlives
/// the buffer it was borrowed from.
///
/// ```zig
/// try query.ownScope(outbox_payload);
/// ```
pub fn ownScope(self: *OwnedHistoryQuery, payload: []u8) !void {
    if (self.scope_value.len > max_scope_bytes or self.scope_value.len > payload.len) {
        return error.ScopeTooLong;
    }

    @memcpy(payload[0..self.scope_value.len], self.scope_value);
    self.scope_value = payload[0..self.scope_value.len];
}
