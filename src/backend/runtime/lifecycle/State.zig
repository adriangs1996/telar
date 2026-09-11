const ClientKeyType = @import("../../history/ClientKey.zig");
const StopRequested = @import("StopRequested.zig");
const State = @This();

requested: bool = false,
initiator: ?ClientKeyType = null,

/// Commits the first shutdown request and returns the event that may be
/// published after the state transition. Later requests are idempotent.
///
/// ```zig
/// if (shutdown.request(client)) |event| {
///     publish(event);
/// }
/// ```
pub fn request(state: *State, initiator: ClientKeyType) ?StopRequested {
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
