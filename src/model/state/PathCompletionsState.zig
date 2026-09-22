//! Client-owned bookkeeping of the directory-completion worker: the
//! query the form wants listed, the one in flight and the next identity.
const PathCompletionState = @import("PathCompletionState.zig");
const PathCompletionResult = @import("PathCompletionResult.zig");
const PathCompletionsState = @This();

next_id: u64 = 1,
/// Execution whose result is awaited; `.none` while the worker is idle.
execution: PathCompletionState.ExecutionId = .none,
wanted: [PathCompletionResult.max_path_bytes]u8 = undefined,
wanted_len: u16 = 0,
inflight: [PathCompletionResult.max_path_bytes]u8 = undefined,
inflight_len: u16 = 0,

pub fn wantedSlice(self: *const PathCompletionsState) []const u8 {
    return self.wanted[0..self.wanted_len];
}

pub fn inflightSlice(self: *const PathCompletionsState) []const u8 {
    return self.inflight[0..self.inflight_len];
}

/// Records the latest query and reports whether it differs from the
/// previous one. Example: `if (!state.want(query)) return;`
pub fn want(self: *PathCompletionsState, query: []const u8) bool {
    if (std.mem.eql(u8, self.wantedSlice(), query)) {
        return false;
    }

    @memcpy(self.wanted[0..query.len], query);
    self.wanted_len = @intCast(query.len);
    return true;
}

/// Reserves an identity for listing the wanted query.
/// Example: `const id = state.reserve();`
pub fn reserve(self: *PathCompletionsState) PathCompletionState.ExecutionId {
    const id: PathCompletionState.ExecutionId = @enumFromInt(self.next_id);
    self.next_id += 1;
    self.execution = id;
    @memcpy(self.inflight[0..self.wanted_len], self.wantedSlice());
    self.inflight_len = self.wanted_len;
    return id;
}

/// Retires the in-flight execution if it is the completed one.
/// Example: `if (!state.finish(completion.execution_id)) return;`
pub fn finish(self: *PathCompletionsState, id: PathCompletionState.ExecutionId) bool {
    if (id == .none or id != self.execution) {
        return false;
    }

    self.execution = .none;
    return true;
}

/// Whether the wanted query moved on while the listing ran.
pub fn superseded(self: *const PathCompletionsState) bool {
    return !std.mem.eql(u8, self.wantedSlice(), self.inflightSlice());
}

pub fn reset(self: *PathCompletionsState) void {
    self.execution = .none;
    self.wanted_len = 0;
    self.inflight_len = 0;
}

const std = @import("std");

test "state reserves one execution, retires only that one and detects superseded queries" {
    var self: PathCompletionsState = .{};
    try std.testing.expect(self.want("/a"));
    try std.testing.expect(!self.want("/a"));
    const first = self.reserve();
    try std.testing.expect(!self.superseded());
    try std.testing.expect(self.want("/ab"));
    try std.testing.expect(self.superseded());
    try std.testing.expect(!self.finish(@enumFromInt(99)));
    try std.testing.expect(self.execution == first);
    try std.testing.expect(self.finish(first));
    try std.testing.expect(self.execution == .none);
    try std.testing.expect(!self.finish(first));
    self.reset();
    try std.testing.expect(self.want("/a"));
}
