//! Runtime shutdown authority and its first-writer transition.

const std = @import("std");
const history_mod = @import("../../history/root.zig");

pub const ClientKey = history_mod.model.ClientKey;

pub const StopRequested = struct {
    initiator: ClientKey,
};

pub const State = struct {
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
    pub fn request(state: *State, initiator: ClientKey) ?StopRequested {
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
};

test "the first shutdown requester becomes the stable authority" {
    var state: State = .{};
    const first: ClientKey = .{ .id = 7, .generation = 3 };
    const second: ClientKey = .{ .id = 8, .generation = 4 };

    try std.testing.expect(!state.isRequested());
    try std.testing.expectEqualDeep(first, state.request(first).?.initiator);
    try std.testing.expect(state.isRequested());
    try std.testing.expectEqualDeep(first, state.initiator.?);

    try std.testing.expect(state.request(first) == null);
    try std.testing.expect(state.request(second) == null);
    try std.testing.expectEqualDeep(first, state.initiator.?);
}
