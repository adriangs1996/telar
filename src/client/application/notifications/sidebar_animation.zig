//! Application policy for the model-owned sidebar animation loop.

const core = @import("telar-core");
const data = @import("model");
const ModelType = @import("../../model/Model.zig");

pub const Activity = enum {
    active,
    inactive,
};

fn reconcileAgent(model: *ModelType, revision: u64, status: core.AgentStatus) !void {
    const agent: data.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = status,
    };

    _ = try model.reconcileAgentSnapshot(.{ .revision = revision, .agents = &.{agent} });
}
