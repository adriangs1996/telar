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

test "a delivered machine target rejects reused pane sessions" {
    var model = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const key: data.AgentKey = .{ .pane_id = @enumFromInt(7), .pane_generation = 1 };
    _ = try model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = key,
        .session_id = .{1} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }} });
    const target: MachineAgent = .{ .slot = 1, .key = key, .session_id = .{1} ** 16 };
    try std.testing.expect(target.resolve(&model) != null);
    model.agent_snapshot.items[0].session_id = .{2} ** 16;
    try std.testing.expect(target.resolve(&model) == null);
    model.agent_snapshot.items[0].session_id = .{1} ** 16;
    model.agent_snapshot.items[0].key.pane_generation += 1;
    try std.testing.expect(target.resolve(&model) == null);
}
