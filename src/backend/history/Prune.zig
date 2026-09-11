const PruneInput = @import("PruneInput.zig");
const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const HistoryScope = @import("telar-core").HistoryScope;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const PaneIdType = @import("telar-core").PaneId;
const max_history_query_bytes = @import("telar-core").max_history_query_bytes;
/// Bounded owned prune filters, mirroring `Query`'s storage discipline.
const Prune = @This();

pub const Input = @import("PruneInput.zig");

request_id: RequestIdType,
origin: QueryOrigin,
scope: HistoryScope = .global,
scope_text: [max_cwd_bytes_module]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: PaneIdType = .invalid,
before_ms: i64 = 0,
failed_only: bool = false,
match: [max_history_query_bytes]u8 = undefined,
match_len: u16 = 0,

pub fn init(input: PruneInput) !Prune {
    if (input.match.len > max_history_query_bytes) {
        return error.QueryTooLong;
    }
    if (input.scope_value.len > max_cwd_bytes_module) {
        return error.ScopeTooLong;
    }
    if (input.scope == .pane and input.pane_id == .invalid) {
        return error.InvalidPaneId;
    }
    if (input.scope != .pane and input.pane_id != .invalid) {
        return error.UnexpectedPaneId;
    }

    var prune: Prune = .{
        .request_id = input.request_id,
        .origin = input.origin,
        .scope = input.scope,
        .pane_id = input.pane_id,
        .before_ms = input.before_ms,
        .failed_only = input.failed_only,
    };
    @memcpy(prune.scope_text[0..input.scope_value.len], input.scope_value);
    prune.scope_text_len = @intCast(input.scope_value.len);
    @memcpy(prune.match[0..input.match.len], input.match);
    prune.match_len = @intCast(input.match.len);
    return prune;
}

pub fn scopeSlice(prune: *const Prune) []const u8 {
    return prune.scope_text[0..prune.scope_text_len];
}

pub fn matchSlice(prune: *const Prune) []const u8 {
    return prune.match[0..prune.match_len];
}
