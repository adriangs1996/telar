const Query = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const std = @import("std");
pub const Input = struct {
    request_id: source_namespace.schema.RequestId,
    origin: QueryOrigin,
    text: []const u8 = "",
    scope: source_namespace.Scope = .global,
    scope_value: []const u8 = "",
    pane_id: source_namespace.schema.PaneId = .invalid,
    failed_only: bool = false,
    author: source_namespace.schema.HistoryAuthorFilter = .all,
    match: source_namespace.schema.HistoryMatch = .fts,
    distinct: bool = false,
    limit: u16 = 20,
    offset: u32 = 0,
    snapshot_id: u64 = 0,
    entry_id: u64 = 0,
};

request_id: source_namespace.schema.RequestId,
origin: QueryOrigin,
text: [source_namespace.max_query_bytes]u8 = undefined,
text_len: u16 = 0,
scope: source_namespace.Scope = .global,
scope_text: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
scope_text_len: u16 = 0,
pane_id: source_namespace.schema.PaneId = .invalid,
failed_only: bool = false,
author: source_namespace.schema.HistoryAuthorFilter = .all,
match: source_namespace.schema.HistoryMatch = .fts,
distinct: bool = false,
limit: u16 = 20,
offset: u32 = 0,
snapshot_id: u64 = 0,
entry_id: u64 = 0,

/// Copies a validated query into fixed storage so it can cross the
/// asynchronous history queue without borrowing request-buffer bytes.
///
/// ```zig
/// const query = try Query.init(.{
///     .request_id = request_id,
///     .origin = origin,
///     .text = "git",
/// });
/// ```
pub fn init(input: Input) !Query {
    if (input.snapshot_id > std.math.maxInt(i64) or input.entry_id > std.math.maxInt(i64)) {
        return error.InvalidHistoryId;
    }

    if (input.text.len > source_namespace.max_query_bytes) {
        return error.QueryTooLong;
    }

    if (input.scope_value.len > source_namespace.schema.max_cwd_bytes) {
        return error.ScopeTooLong;
    }

    if (input.limit == 0 or input.limit > source_namespace.max_results) {
        return error.InvalidLimit;
    }

    if (input.scope == .pane and input.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    if (input.scope != .pane and input.pane_id != .invalid) {
        return error.UnexpectedPaneId;
    }

    var query: Query = .{
        .request_id = input.request_id,
        .origin = input.origin,
        .scope = input.scope,
        .pane_id = input.pane_id,
        .failed_only = input.failed_only,
        .author = input.author,
        .match = input.match,
        .distinct = input.distinct,
        .limit = input.limit,
        .offset = input.offset,
        .snapshot_id = input.snapshot_id,
        .entry_id = input.entry_id,
    };
    @memcpy(query.text[0..input.text.len], input.text);
    query.text_len = @intCast(input.text.len);
    @memcpy(query.scope_text[0..input.scope_value.len], input.scope_value);
    query.scope_text_len = @intCast(input.scope_value.len);
    return query;
}

/// Returns the query text owned by this value.
///
/// ```zig
/// const text = query.textSlice();
/// ```
pub fn textSlice(query: *const Query) []const u8 {
    return query.text[0..query.text_len];
}

/// Returns the cwd or workspace scope text owned by this value.
///
/// ```zig
/// const scope = query.scopeSlice();
/// ```
pub fn scopeSlice(query: *const Query) []const u8 {
    return query.scope_text[0..query.scope_text_len];
}
