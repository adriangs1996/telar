//! Connects the sidebar animation use case to the client timer.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const ActivityType = @import("../../application/notifications/sidebar_animation.zig").Activity;
const SidebarAnimationChangeType = @import("../../model/SidebarAnimationChange.zig");
const SidebarAnimationHandlerType = @import("../../application/notifications/SidebarAnimationHandler.zig");
const monotonic_module = @import("../../resources/clock.zig").monotonic;

const interval_ns = 120 * std.time.ns_per_ms;

/// Ensures the current model has one future tick when animation is active.
///
/// ```zig
/// _ = try synchronize(client);
/// ```
pub fn synchronize(client: *Client) !ActivityType {
    var use_case = handler(client);

    return use_case.synchronize();
}

/// Completes one timer, advances the model and rearms only active animation.
///
/// ```zig
/// _ = try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !?SidebarAnimationChangeType {
    try client.sidebar_animation_scheduler.complete(result);

    var use_case = handler(client);

    return use_case.tick();
}

fn handler(client: *Client) SidebarAnimationHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .schedule = schedule,
        },
    };
}

fn schedule(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
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
