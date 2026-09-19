const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const PaneRef = @import("PaneRef.zig");
const ManagedAgent = @This();

session: *Session,
pane: PaneRef,

/// Interrupts exactly the resolved pane generation. Example: `try managed.interrupt();`
pub fn interrupt(self: *ManagedAgent) !void {
    const response = try self.session.exchange(core.encodeAgentInterrupt, core.AgentInterrupt{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}
