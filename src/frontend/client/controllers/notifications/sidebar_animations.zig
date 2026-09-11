//! Connects the sidebar animation use case to the client timer.

const std = @import("std");
const Client = @import("../../Client.zig");
const ActivityType = @import("telar-client").Activity;
const SidebarAnimationChangeType = @import("telar-client").SidebarAnimationChange;
const SidebarAnimationHandlerType = @import("telar-client").SidebarAnimationHandler;
const monotonic_module = @import("telar-client").monotonic;

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
    client.sidebar_animation_scheduler.pending = false;
    try result;

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
    scheduler.pending = true;
    client.select.concurrent(.sidebar_animation_tick, waitUntil, .{
        client.io,
        deadline_ns,
    }) catch |err| {
        scheduler.pending = false;
        return err;
    };
}

fn waitUntil(io: std.Io, deadline_ns: u64) anyerror!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}
