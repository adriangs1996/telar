const State = @This();
const source_namespace = @import("shutdown_authority.zig");
const StopRequested = @import("StopRequested.zig");
requested: bool = false,
initiator: ?source_namespace.ClientKey = null,

/// Commits the first shutdown request and returns the event that may be
/// published after the state transition. Later requests are idempotent.
///
/// ```zig
/// if (shutdown.request(client)) |event| {
///     publish(event);
/// }
/// ```
pub fn request(state: *State, initiator: source_namespace.ClientKey) ?StopRequested {
    if (state.requested) {
        return null;
    }

    state.requested = true;
    state.initiator = initiator;
    return .{ .initiator = initiator };
}

/// Reports whether the runtime has crossed the shutdown boundary.
///
/// ```zig
/// if (shutdown.isRequested()) {
///     stop_accepting_clients();
/// }
/// ```
pub fn isRequested(state: *const State) bool {
    return state.requested;
}
