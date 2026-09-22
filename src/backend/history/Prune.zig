const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
/// Bounded owned prune filters, mirroring `Query`'s storage discipline.
const Prune = @This();

pub const Input = @import("PruneInput.zig");

request_id: core.RequestId,
origin: QueryOrigin,
scope: core.HistoryScope = .global,
scope_text: [core.max_cwd_bytes]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: core.PaneId = .invalid,
before_ms: i64 = 0,
failed_only: bool = false,
match: [core.max_history_query_bytes]u8 = undefined,
match_len: u16 = 0,

pub fn init(input: Input) !Prune {
    if (input.match.len > core.max_history_query_bytes) {
        return error.QueryTooLong;
    }
    if (input.scope_value.len > core.max_cwd_bytes) {
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
