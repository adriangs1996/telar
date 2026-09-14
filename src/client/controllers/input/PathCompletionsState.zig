//! Controller-owned bookkeeping of the directory-completion worker: the
//! query the form wants listed, the one in flight and the next identity.
const ExecutionIdType = @import("../../model/PathCompletionState.zig").ExecutionId;
const max_path_bytes_module = @import("../../model/PathCompletionResult.zig").max_path_bytes;
const State = @This();

next_id: u64 = 1,
/// Execution whose result is awaited; `.none` while the worker is idle.
execution: ExecutionIdType = .none,
wanted: [max_path_bytes_module]u8 = undefined,
wanted_len: u16 = 0,
inflight: [max_path_bytes_module]u8 = undefined,
inflight_len: u16 = 0,

pub fn wantedSlice(state: *const State) []const u8 {
    return state.wanted[0..state.wanted_len];
}

pub fn inflightSlice(state: *const State) []const u8 {
    return state.inflight[0..state.inflight_len];
}

/// Records the latest query and reports whether it differs from the
/// previous one. Example: `if (!state.want(query)) return;`
pub fn want(state: *State, query: []const u8) bool {
    if (std.mem.eql(u8, state.wantedSlice(), query)) {
        return false;
    }

    @memcpy(state.wanted[0..query.len], query);
    state.wanted_len = @intCast(query.len);
    return true;
}

/// Reserves an identity for listing the wanted query.
/// Example: `const id = state.reserve();`
pub fn reserve(state: *State) ExecutionIdType {
    const id: ExecutionIdType = @enumFromInt(state.next_id);
    state.next_id += 1;
    state.execution = id;
    @memcpy(state.inflight[0..state.wanted_len], state.wantedSlice());
    state.inflight_len = state.wanted_len;
    return id;
}

/// Retires the in-flight execution if it is the completed one.
/// Example: `if (!state.finish(completion.execution_id)) return;`
pub fn finish(state: *State, id: ExecutionIdType) bool {
    if (id == .none or id != state.execution) {
        return false;
    }

    state.execution = .none;
    return true;
}

/// Whether the wanted query moved on while the listing ran.
pub fn superseded(state: *const State) bool {
    return !std.mem.eql(u8, state.wantedSlice(), state.inflightSlice());
}

pub fn reset(state: *State) void {
    state.execution = .none;
    state.wanted_len = 0;
    state.inflight_len = 0;
}

const std = @import("std");

test "state reserves one execution, retires only that one and detects superseded queries" {
    var state: State = .{};
    try std.testing.expect(state.want("/a"));
    try std.testing.expect(!state.want("/a"));
    const first = state.reserve();
    try std.testing.expect(!state.superseded());
    try std.testing.expect(state.want("/ab"));
    try std.testing.expect(state.superseded());
    try std.testing.expect(!state.finish(@enumFromInt(99)));
    try std.testing.expect(state.execution == first);
    try std.testing.expect(state.finish(first));
    try std.testing.expect(state.execution == .none);
    try std.testing.expect(!state.finish(first));
    state.reset();
    try std.testing.expect(state.want("/a"));
}
