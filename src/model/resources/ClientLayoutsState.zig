const Version = @import("LayoutSyncVersion.zig");
const State = @This();

snapshot_received: bool = false,
last_sent: ?Version = null,

/// Opens layout synchronization after the runtime's one bootstrap
/// snapshot has been consumed.
///
/// ```zig
/// state.markSnapshotReceived();
/// ```
pub fn markSnapshotReceived(self: *State) !void {
    if (self.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    self.snapshot_received = true;
}
