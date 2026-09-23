const ClientKey = @import("../../history/ClientKey.zig");
const State = @This();

requested: bool = false,
initiator: ?ClientKey = null,

/// Commits the first shutdown request and returns the event that may be
/// published after the state transition. Later requests are idempotent.
///
/// ```zig
/// if (shutdown.request(client)) |event| {
///     publish(event);
/// }
/// ```
pub fn request(self: *State, initiator: ClientKey) ?StopRequested {
    if (self.requested) {
        return null;
    }

    self.requested = true;
    self.initiator = initiator;
    return .{ .initiator = initiator };
}

/// Reports whether the runtime has crossed the shutdown boundary.
///
/// ```zig
/// if (shutdown.isRequested()) {
///     stop_accepting_clients();
/// }
/// ```
pub fn isRequested(self: *const State) bool {
    return self.requested;
}

const StopRequested = struct {
    initiator: ClientKey,
};
