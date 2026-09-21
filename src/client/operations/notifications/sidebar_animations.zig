//! Connects the sidebar animation use case to the client timer.

const core = @import("telar-core");
const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const ActivityType = @import("../../application/notifications/sidebar_animation.zig").Activity;
const SidebarAnimationChangeType = @import("../../model/SidebarAnimationChange.zig");
const monotonic_module = core.monotonic;

const interval_ns = 120 * std.time.ns_per_ms;

/// Ensures the current model has one future tick when animation is active.
///
/// ```zig
/// _ = try synchronize(client);
/// ```
pub fn synchronize(client: *Client) !ActivityType {
    if (!client.model.sidebarAnimationActive()) {
        return .inactive;
    }

    try schedule(client);
    return .active;
}

/// Completes one timer, advances the model and rearms only active animation.
///
/// ```zig
/// _ = try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !?SidebarAnimationChangeType {
    try client.sidebar_animation_scheduler.complete(result);
    const change = client.model.advanceSidebarAnimation() orelse return null;
    try schedule(client);
    return change;
}

fn schedule(client: *Client) !void {
    if (client.timers.animation_clock == .host) {
        return;
    }

    const scheduler = &client.sidebar_animation_scheduler;
    if (scheduler.pending) {
        return;
    }

    const deadline_ns = monotonic_module(client.io) +| interval_ns;
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.timers.arm(.sidebar_animation, scheduler) catch |err| {
            scheduler.schedulingFailed();
            return err;
        },
    }
}
