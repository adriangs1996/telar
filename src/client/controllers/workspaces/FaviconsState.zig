//! Controller-owned bookkeeping of the favicon worker: the one lookup in
//! flight, its workspace and the next execution identity. Results for any
//! other execution are stale and released unread.
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const State = @This();

pub const ExecutionId = enum(u64) {
    none = 0,
    _,
};

next_id: u64 = 1,
/// Execution whose result is awaited; `.none` while the worker is idle.
execution: ExecutionId = .none,
workspace: WorkspaceIdType = .invalid,

/// Reserves an identity for looking up `workspace`.
/// Example: `const id = state.reserve(workspace);`
pub fn reserve(state: *State, workspace: WorkspaceIdType) ExecutionId {
    const id: ExecutionId = @enumFromInt(state.next_id);
    state.next_id += 1;
    state.execution = id;
    state.workspace = workspace;
    return id;
}

/// Retires the in-flight execution if it is the completed one.
/// Example: `if (!state.finish(completion.execution_id)) return null;`
pub fn finish(state: *State, id: ExecutionId) bool {
    if (id == .none or id != state.execution) {
        return false;
    }

    state.execution = .none;
    state.workspace = .invalid;
    return true;
}

/// Forgets the in-flight lookup; its result will be released unread.
/// Example: `state.reset();`
pub fn reset(state: *State) void {
    state.execution = .none;
    state.workspace = .invalid;
}

pub fn busy(state: *const State) bool {
    return state.execution != .none;
}

const std = @import("std");

test "one execution is reserved, only that one finishes and a reset orphans it" {
    var state: State = .{};
    try std.testing.expect(!state.busy());
    const first = state.reserve(@enumFromInt(7));
    try std.testing.expect(state.busy());
    try std.testing.expect(!state.finish(@enumFromInt(99)));
    try std.testing.expect(!state.finish(.none));
    try std.testing.expect(state.finish(first));
    try std.testing.expect(!state.finish(first));
    const second = state.reserve(@enumFromInt(8));
    try std.testing.expect(second != first);
    state.reset();
    try std.testing.expect(!state.finish(second));
}
