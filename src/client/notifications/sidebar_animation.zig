//! Application policy for the model-owned sidebar animation loop.

const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const Client = @import("../execution/Client.zig");

pub const Activity = enum {
    active,
    inactive,
};

fn reconcileAgent(model: *data.ClientModel, revision: u64, status: core.AgentStatus) !void {
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

const sidebar_animation_interval_ns = 120 * std.time.ns_per_ms;

/// Completes one timer, advances the model and rearms only active animation.
/// Example: `_ = try sidebar_animation.completeSidebarAnimationTick(client, result);`
pub fn completeSidebarAnimationTick(client: *Client, result: anyerror!void) !?data.SidebarAnimationChange {
    try client.model.sidebar_animation_scheduler.complete(result);
    const change = client.model.advanceSidebarAnimation() orelse return null;
    try scheduleSidebarAnimation(client);
    return change;
}

/// Ensures the current model has one future tick when animation is active.
pub fn synchronizeSidebarAnimation(client: *Client) !Activity {
    if (!client.model.sidebarAnimationActive()) {
        return .inactive;
    }

    try scheduleSidebarAnimation(client);
    return .active;
}

fn scheduleSidebarAnimation(client: *Client) !void {
    if (client.model.host.animation_frame_ns == null) {
        return;
    }

    const scheduler = &client.model.sidebar_animation_scheduler;
    if (scheduler.pending) {
        return;
    }

    const deadline_ns = core.monotonic(client.io) +| sidebar_animation_interval_ns;
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.to_workers.push(.{ .timer = .{ .kind = .sidebar_animation, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();
            return err;
        },
    }
}
