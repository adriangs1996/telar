/// Bounded owned stats filters.
const StatsQuery = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
pub const Input = struct {
    request_id: source_namespace.schema.RequestId,
    origin: QueryOrigin,
    scope: source_namespace.Scope = .global,
    scope_value: []const u8 = "",
    pane_id: source_namespace.schema.PaneId = .invalid,
    since_ms: i64 = 0,
};

request_id: source_namespace.schema.RequestId,
origin: QueryOrigin,
scope: source_namespace.Scope = .global,
scope_text: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: source_namespace.schema.PaneId = .invalid,
since_ms: i64 = 0,

pub fn init(input: Input) !StatsQuery {
    if (input.scope_value.len > source_namespace.schema.max_cwd_bytes) {
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
