//! Application policy for the model-owned sidebar animation loop.

const pacing = @import("pacing");
const data = @import("model");
const std = @import("std");
const Client = @import("../execution/Client.zig");

pub const Activity = enum {
    active,
    inactive,
};

const sidebar_animation_interval_ns = 120 * std.time.ns_per_ms;

/// Completes one timer, advances the model and rearms only active animation.
/// Example: `_ = try sidebar_animation.completeSidebarAnimationTick(client, result);`
pub fn completeSidebarAnimationTick(client: *Client, result: anyerror!void) !?data.SidebarAnimationChange {
    try client.model.sidebar_animation_scheduler.complete(result);
    const change = data.sidebar_animation.advance(&client.model) orelse return null;
    try scheduleSidebarAnimation(client);
    return change;
}

/// Ensures the current model has one future tick when animation is active.
pub fn synchronizeSidebarAnimation(client: *Client) !Activity {
    if (!data.sidebar_animation.isActive(&client.model)) {
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

    const deadline_ns = pacing.clock.monotonic(client.io) +| sidebar_animation_interval_ns;
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.to_workers.push(.{ .timer = .{ .kind = .sidebar_animation, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();
            return err;
        },
    }
}
