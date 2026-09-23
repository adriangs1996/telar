//! The working-directory completion list: the query the form wants listed,
//! the one the worker is listing, and the last landed result. One execution
//! is awaited at a time; any other result is stale and ignored.
const Result = @import("PathCompletionResult.zig");
const Entry = @import("PathCompletionEntry.zig");
const Landing = @import("PathCompletionLanding.zig");
const State = @This();

pub const ExecutionId = enum(u64) {
    none = 0,
    _,
};

revision: u64 = 0,
next_id: u64 = 1,
/// Execution whose result is awaited; `.none` while the worker is idle.
pending: ExecutionId = .none,
wanted: [Result.max_path_bytes]u8 = undefined,
wanted_len: u16 = 0,
inflight: [Result.max_path_bytes]u8 = undefined,
inflight_len: u16 = 0,
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
    state.forgetQuery();
    state.revision +%= 1;
}

/// Forgets the wanted and in-flight queries; a running listing lands into
/// nothing.
///
/// ```zig
/// model.path_completion.forgetQuery();
/// ```
pub fn forgetQuery(state: *State) void {
    state.pending = .none;
    state.wanted_len = 0;
    state.inflight_len = 0;
}

pub fn wantedSlice(state: *const State) []const u8 {
    return state.wanted[0..state.wanted_len];
}

pub fn inflightSlice(state: *const State) []const u8 {
    return state.inflight[0..state.inflight_len];
}

/// Records the latest query and reports whether it differs from the
/// previous one.
///
/// ```zig
/// if (!model.path_completion.want(query)) return;
/// ```
pub fn want(state: *State, query: []const u8) bool {
    if (std.mem.eql(u8, state.wantedSlice(), query)) {
        return false;
    }

    @memcpy(state.wanted[0..query.len], query);
    state.wanted_len = @intCast(query.len);
    return true;
}

/// Reserves the execution that lists the wanted query. The previous list
/// stays visible until the new one lands, so typing does not flicker.
///
/// ```zig
/// const id = model.path_completion.reserve();
/// ```
pub fn reserve(state: *State) ExecutionId {
    const id: ExecutionId = @enumFromInt(state.next_id);
    state.next_id += 1;
    state.pending = id;
    @memcpy(state.inflight[0..state.wanted_len], state.wantedSlice());
    state.inflight_len = state.wanted_len;
    return id;
}

/// Retires the awaited execution and reports whether `execution_id` was it.
///
/// ```zig
/// if (!model.path_completion.retire(completion.execution_id)) return;
/// ```
pub fn retire(state: *State, execution_id: ExecutionId) bool {
    if (execution_id == .none or execution_id != state.pending) {
        return false;
    }

    state.pending = .none;
    return true;
}

/// Whether the wanted query moved on while the listing ran.
pub fn superseded(state: *const State) bool {
    return !std.mem.eql(u8, state.wantedSlice(), state.inflightSlice());
}

/// Lands the result of a retired execution for the query it listed.
///
/// ```zig
/// model.path_completion.land(.{ .query = query, .result = &result });
/// ```
pub fn land(state: *State, landing: Landing) void {
    state.result = landing.result.*;
    const len = @min(landing.query.len, state.query.len);
    @memcpy(state.query[0..len], landing.query[0..len]);
    state.query_len = @intCast(len);
    state.revision +%= 1;
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
    try std.testing.expect(state.want("/work/t"));
    try std.testing.expect(!state.want("/work/t"));
    const id = state.reserve();
    try std.testing.expect(!state.retire(@enumFromInt(@intFromEnum(id) + 1)));
    try std.testing.expect(state.retire(id));
    try std.testing.expect(!state.superseded());
    state.land(.{ .query = "/work/t", .result = &result });
    try std.testing.expectEqual(@as(usize, 1), state.entries().len);
    try std.testing.expect(state.matches("/work/t"));
    try std.testing.expect(!state.retire(id));

    const before = state.version();
    state.invalidate();
    try std.testing.expectEqual(before + 1, state.version());
    state.invalidate();
    try std.testing.expectEqual(before + 1, state.version());
    try std.testing.expect(!state.matches("/work/t"));
}

test "a query typed while the listing runs supersedes it" {
    var state: State = .{};
    _ = state.want("/a");
    const first = state.reserve();
    try std.testing.expect(!state.superseded());
    try std.testing.expect(state.want("/ab"));
    try std.testing.expect(state.superseded());
    try std.testing.expect(state.retire(first));
    state.forgetQuery();
    try std.testing.expect(state.want("/a"));
}
