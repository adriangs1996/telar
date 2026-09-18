const PaneId = @import("../id.zig").PaneId;
const Snapshot = @import("../../AgentThreadSnapshot.zig");
const Decoder = @import("../Decoder.zig");

pane_id: PaneId,
pane_generation: u64,
revision: u64,
encoded: []const u8,

/// Copies a validated wire view into client-owned bounded storage.
/// Example: `try view.copyTo(snapshot);`.
pub fn copyTo(view: @This(), snapshot: *Snapshot) !void {
    var decoder = Decoder.init(view.encoded);
    _ = try @import("agent_thread.zig").decodeSnapshotBody(&decoder, snapshot);
    try decoder.ensureEnd();
}
