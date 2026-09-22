//! Client-owned bookkeeping of the favicon worker: the one lookup in
//! flight, its workspace and the next execution identity. Results for any
//! other execution are stale and released unread.
const core = @import("telar-core");
const FaviconsState = @This();

pub const ExecutionId = enum(u64) {
    none = 0,
    _,
};

next_id: u64 = 1,
/// Execution whose result is awaited; `.none` while the worker is idle.
execution: ExecutionId = .none,
workspace: core.WorkspaceId = .invalid,

/// Reserves an identity for looking up `workspace`.
/// Example: `const id = state.reserve(workspace);`
pub fn reserve(self: *FaviconsState, workspace: core.WorkspaceId) ExecutionId {
    const id: ExecutionId = @enumFromInt(self.next_id);
    self.next_id += 1;
    self.execution = id;
    self.workspace = workspace;
    return id;
}

/// Retires the in-flight execution if it is the completed one.
/// Example: `if (!state.finish(completion.execution_id)) return null;`
pub fn finish(self: *FaviconsState, id: ExecutionId) bool {
    if (id == .none or id != self.execution) {
        return false;
    }

    self.execution = .none;
    self.workspace = .invalid;
    return true;
}

/// Forgets the in-flight lookup; its result will be released unread.
/// Example: `state.reset();`
pub fn reset(self: *FaviconsState) void {
    self.execution = .none;
    self.workspace = .invalid;
}

pub fn busy(self: *const FaviconsState) bool {
    return self.execution != .none;
}

const std = @import("std");

test "one execution is reserved, only that one finishes and a reset orphans it" {
    var self: FaviconsState = .{};
    try std.testing.expect(!self.busy());
    const first = self.reserve(@enumFromInt(7));
    try std.testing.expect(self.busy());
    try std.testing.expect(!self.finish(@enumFromInt(99)));
    try std.testing.expect(!self.finish(.none));
    try std.testing.expect(self.finish(first));
    try std.testing.expect(!self.finish(first));
    const second = self.reserve(@enumFromInt(8));
    try std.testing.expect(second != first);
    self.reset();
    try std.testing.expect(!self.finish(second));
}
