const StatsQueryInput = @import("StatsQueryInput.zig");
const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const HistoryScope = @import("telar-core").HistoryScope;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const PaneIdType = @import("telar-core").PaneId;
/// Bounded owned stats filters.
const StatsQuery = @This();

pub const Input = @import("StatsQueryInput.zig");

request_id: RequestIdType,
origin: QueryOrigin,
scope: HistoryScope = .global,
scope_text: [max_cwd_bytes_module]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: PaneIdType = .invalid,
since_ms: i64 = 0,

pub fn init(input: StatsQueryInput) !StatsQuery {
    if (input.scope_value.len > max_cwd_bytes_module) {
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

pub fn scopeSlice(query: *const StatsQuery) []const u8 {
    return query.scope_text[0..query.scope_text_len];
}
