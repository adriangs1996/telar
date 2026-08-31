//! Connects the sidebar animation use case to the client timer.

const std = @import("std");
const client_application = @import("application/root.zig");
const client_clock = @import("clock.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const Io = std.Io;
const sidebar_animation = client_application.sidebar_animation;

const interval_ns = 120 * std.time.ns_per_ms;

pub const Scheduler = struct {
    pending: bool = false,
};

/// Ensures the current model has one future tick when animation is active.
///
/// ```zig
/// _ = try synchronize(client);
/// ```
pub fn synchronize(client: *Client) !sidebar_animation.Activity {
    var use_case = handler(client);

    return use_case.synchronize();
}

/// Completes one timer, advances the model and rearms only active animation.
///
/// ```zig
/// _ = try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !?client_model.SidebarAnimationChange {
    client.sidebar_animation_scheduler.pending = false;
    try result;

    var use_case = handler(client);

    return use_case.tick();
}

fn handler(client: *Client) sidebar_animation.SidebarAnimationHandler {
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

    const deadline_ns = client_clock.monotonic(client.io) +| interval_ns;
    scheduler.pending = true;
    client.select.concurrent(.sidebar_animation_tick, waitUntil, .{
        client.io,
        deadline_ns,
    }) catch |err| {
        scheduler.pending = false;
        return err;
    };
}

fn waitUntil(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}
