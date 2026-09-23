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
pub fn begin(self: *State) void {
    self.pending = .none;
    self.result = .{};
    self.query_len = 0;
    self.forgetQuery();
    self.revision +%= 1;
}

/// Forgets the wanted and in-flight queries; a running listing lands into
/// nothing.
///
/// ```zig
/// model.path_completion.forgetQuery();
/// ```
pub fn forgetQuery(self: *State) void {
    self.pending = .none;
    self.wanted_len = 0;
    self.inflight_len = 0;
}

pub fn wantedSlice(self: *const State) []const u8 {
    return self.wanted[0..self.wanted_len];
}

pub fn inflightSlice(self: *const State) []const u8 {
    return self.inflight[0..self.inflight_len];
}

/// Records the latest query and reports whether it differs from the
/// previous one.
///
/// ```zig
/// if (!model.path_completion.want(query)) return;
/// ```
pub fn want(self: *State, query: []const u8) bool {
    if (std.mem.eql(u8, self.wantedSlice(), query)) {
        return false;
    }

    @memcpy(self.wanted[0..query.len], query);
    self.wanted_len = @intCast(query.len);
    return true;
}

/// Reserves the execution that lists the wanted query. The previous list
/// stays visible until the new one lands, so typing does not flicker.
///
/// ```zig
/// const id = model.path_completion.reserve();
/// ```
pub fn reserve(self: *State) ExecutionId {
    const id: ExecutionId = @enumFromInt(self.next_id);
    self.next_id += 1;
    self.pending = id;
    @memcpy(self.inflight[0..self.wanted_len], self.wantedSlice());
    self.inflight_len = self.wanted_len;
    return id;
}

/// Retires the awaited execution and reports whether `execution_id` was it.
///
/// ```zig
/// if (!model.path_completion.retire(completion.execution_id)) return;
/// ```
pub fn retire(self: *State, execution_id: ExecutionId) bool {
    if (execution_id == .none or execution_id != self.pending) {
        return false;
    }

    self.pending = .none;
    return true;
}

/// Whether the wanted query moved on while the listing ran.
pub fn superseded(self: *const State) bool {
    return !std.mem.eql(u8, self.wantedSlice(), self.inflightSlice());
}

/// Lands the result of a retired execution for the query it listed.
///
/// ```zig
/// model.path_completion.land(.{ .query = query, .result = &result });
/// ```
pub fn land(self: *State, landing: Landing) void {
    self.result = landing.result.*;
    const len = @min(landing.query.len, self.query.len);
    @memcpy(self.query[0..len], landing.query[0..len]);
    self.query_len = @intCast(len);
    self.revision +%= 1;
}

/// Drops the visible list because the query changed to something the
/// worker has not seen yet.
///
/// ```zig
/// model.path_completion.invalidate();
/// ```
pub fn invalidate(self: *State) void {
    if (self.result.len == 0 and self.query_len == 0 and !self.result.exact_exists) {
        return;
    }

    self.result = .{};
    self.query_len = 0;
    self.revision +%= 1;
}

pub fn entries(self: *const State) []const Entry {
    return self.result.slice();
}

pub fn querySlice(self: *const State) []const u8 {
    return self.query[0..self.query_len];
}

/// Whether a landed result describes this expanded query.
pub fn matches(self: *const State, query: []const u8) bool {
    return self.pending == .none and std.mem.eql(u8, self.querySlice(), query);
}

pub fn version(self: *const State) u64 {
    return self.revision;
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
