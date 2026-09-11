const State = @This();
const std = @import("std");
pending: bool = false,

/// Reports whether a generator actor still owns the global description
/// slot, even if its agent aggregate has already been retired.
///
/// ```zig
/// if (state.isPending()) {
///     return;
/// }
/// ```
pub fn isPending(state: *const State) bool {
    return state.pending;
}

pub fn begin(state: *State) void {
    std.debug.assert(!state.pending);
    state.pending = true;
}

pub fn complete(state: *State) void {
    std.debug.assert(state.pending);
    state.pending = false;
}
