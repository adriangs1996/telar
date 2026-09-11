const Version = @import("Version.zig");
const State = @This();

snapshot_received: bool = false,
last_sent: ?Version = null,

/// Opens layout synchronization after the runtime's one bootstrap
/// snapshot has been consumed.
///
/// ```zig
/// state.markSnapshotReceived();
/// ```
pub fn markSnapshotReceived(state: *State) !void {
    if (state.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    state.snapshot_received = true;
}
