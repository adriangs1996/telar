//! Application policy for the model-owned sidebar animation loop.

const ModelType = @import("../../model/Model.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const AgentInputType = @import("../../agents/AgentInput.zig");
const std = @import("std");

pub const Activity = enum {
    active,
    inactive,
};

fn reconcileAgent(model: *ModelType, revision: u64, status: AgentStatusType) !void {
    const agent: AgentInputType = .{
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
