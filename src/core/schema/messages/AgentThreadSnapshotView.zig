const agent_thread = @import("agent_thread.zig");
const id = @import("../id.zig");
const Snapshot = @import("../../AgentThreadSnapshot.zig");
const Decoder = @import("../Decoder.zig");

pane_id: id.PaneId,
pane_generation: u64,
revision: u64,
encoded: []const u8,

/// Copies a validated wire view into client-owned bounded storage.
/// Example: `try view.copyTo(snapshot);`.
pub fn copyTo(view: @This(), snapshot: *Snapshot) !void {
    var decoder = Decoder.init(view.encoded);
    _ = try agent_thread.decodeSnapshotBody(&decoder, snapshot);
    try decoder.ensureEnd();
}
