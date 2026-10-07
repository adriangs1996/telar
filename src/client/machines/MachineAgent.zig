const std = @import("std");
const data = @import("model");
const MachineAgent = @This();

slot: u8,
key: data.AgentKey,
session_id: [16]u8,

/// Resolves a delivered card against the owning replica, rejecting pane reuse.
/// Example: `const agent = target.resolve(&clients[target.slot].model) orelse return;`
pub fn resolve(self: MachineAgent, model: *const data.ClientModel) ?*const data.Agent {
    const agent = model.agent_snapshot.find(self.key) orelse return null;
    return if (std.mem.eql(u8, &agent.session_id, &self.session_id)) agent else null;
}
