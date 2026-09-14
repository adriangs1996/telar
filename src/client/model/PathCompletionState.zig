//! Disposable client state of the working-directory completion list. One
//! execution is awaited at a time; any other result is stale and ignored.
const Result = @import("PathCompletionResult.zig");
const Entry = @import("PathCompletionEntry.zig");
const Landing = @import("PathCompletionLanding.zig");
const State = @This();

pub const ExecutionId = enum(u64) {
    none = 0,
    _,
};

revision: u64 = 0,
pending: ExecutionId = .none,
result: Result = .{},
/// The result belongs to this expanded query; it is empty until one lands.
query: [Result.max_path_bytes]u8 = undefined,
query_len: u16 = 0,

/// Clears everything when the form opens or closes.
///
/// ```zig
/// model.path_completion.begin();
/// ```
pub fn begin(state: *State) void {
    state.pending = .none;
    state.result = .{};
    state.query_len = 0;
    state.revision +%= 1;
}

/// Records the execution whose result is awaited. The previous list stays
/// visible until the new one lands, so typing does not flicker.
///
/// ```zig
/// model.path_completion.expect(execution_id);
/// ```
pub fn expect(state: *State, execution_id: ExecutionId) void {
    state.pending = execution_id;
}

/// Lands one result. Results for any other execution change nothing.
///
/// ```zig
/// _ = model.path_completion.apply(execution_id, query, &result);
/// ```
pub fn apply(state: *State, execution_id: ExecutionId, landing: Landing) bool {
    if (execution_id == .none or execution_id != state.pending) {
        return false;
    }

    state.pending = .none;
    state.result = landing.result.*;
    const len = @min(landing.query.len, state.query.len);
    @memcpy(state.query[0..len], landing.query[0..len]);
    state.query_len = @intCast(len);
    state.revision +%= 1;
    return true;
}

/// Drops the visible list because the query changed to something the
/// worker has not seen yet.
///
/// ```zig
/// model.path_completion.invalidate();
/// ```
pub fn invalidate(state: *State) void {
    if (state.result.len == 0 and state.query_len == 0 and !state.result.exact_exists) {
        return;
    }

    state.result = .{};
    state.query_len = 0;
    state.revision +%= 1;
}

pub fn entries(state: *const State) []const Entry {
    return state.result.slice();
}

pub fn querySlice(state: *const State) []const u8 {
    return state.query[0..state.query_len];
}

/// Whether a landed result describes this expanded query.
pub fn matches(state: *const State, query: []const u8) bool {
    return state.pending == .none and std.mem.eql(u8, state.querySlice(), query);
}

pub fn version(state: *const State) u64 {
    return state.revision;
}

const std = @import("std");

test "only the awaited execution lands and invalidation clears the list once" {
    var state: State = .{};
    state.begin();
    var result: Result = .{};
    try result.setBase("/work");
    try result.append("telar");
    state.expect(@enumFromInt(3));
    try std.testing.expect(!state.apply(@enumFromInt(2), .{ .query = "/work/t", .result = &result }));
    try std.testing.expect(state.apply(@enumFromInt(3), .{ .query = "/work/t", .result = &result }));
    try std.testing.expectEqual(@as(usize, 1), state.entries().len);
    try std.testing.expect(state.matches("/work/t"));
    try std.testing.expect(!state.apply(@enumFromInt(3), .{ .query = "/work/t", .result = &result }));

    const before = state.version();
    state.invalidate();
    try std.testing.expectEqual(before + 1, state.version());
    state.invalidate();
    try std.testing.expectEqual(before + 1, state.version());
    try std.testing.expect(!state.matches("/work/t"));
}
