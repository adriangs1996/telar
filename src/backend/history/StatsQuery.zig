const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
/// Bounded owned stats filters.
const StatsQuery = @This();

pub const Input = @import("StatsQueryInput.zig");

request_id: core.RequestId,
origin: QueryOrigin,
scope: core.HistoryScope = .global,
scope_text: [core.max_cwd_bytes]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: core.PaneId = .invalid,
since_ms: i64 = 0,

pub fn init(input: Input) !StatsQuery {
    if (input.scope_value.len > core.max_cwd_bytes) {
        return error.ScopeTooLong;
    }
    if (input.scope == .pane and input.pane_id == .invalid) {
        return error.InvalidPaneId;
    }
    if (input.scope != .pane and input.pane_id != .invalid) {
        return error.UnexpectedPaneId;
    }

    var query: StatsQuery = .{
        .request_id = input.request_id,
        .origin = input.origin,
        .scope = input.scope,
        .pane_id = input.pane_id,
        .since_ms = input.since_ms,
    };
    @memcpy(query.scope_text[0..input.scope_value.len], input.scope_value);
    query.scope_text_len = @intCast(input.scope_value.len);
    return query;
}

pub fn scopeSlice(self: *const StatsQuery) []const u8 {
    return self.scope_text[0..self.scope_text_len];
}
