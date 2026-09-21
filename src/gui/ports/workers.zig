//! Bounded shared-client jobs run as inbox producers, outside native callbacks.
const std = @import("std");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const NativeLoop = @import("../NativeLoop.zig");

/// Timer tasks borrow their scheduler and complete through this native loop.
/// Example: `app.timers = workers.timers(loop);`
pub fn timers(loop: *NativeLoop) client.HostTimers {
    return .{
        .context = loop,
        .arm_fn = arm,
        .animation_clock = .host,
    };
}

/// Example: `app.bar_runner = workers.bars(app);`
pub fn bars(app: *client.AttachedClient) client.BarCommandRunner {
    return .{ .context = app, .start_fn = startBar };
}

/// Example: `app.path_completion_runner = workers.pathCompletions(app);`
pub fn pathCompletions(app: *client.AttachedClient) client.PathCompletionRunner {
    return .{ .context = app, .start_fn = startPathCompletion };
}

/// Example: `app.favicon_runner = workers.favicons(app);`
pub fn favicons(app: *client.AttachedClient) client.FaviconRunner {
    return .{ .context = app, .start_fn = startFavicon };
}

/// Example: `app.plugin_runner = workers.plugins(app);`
pub fn plugins(app: *client.AttachedClient) client.PluginWorkerRunner {
    return .{ .context = app, .start_fn = startPlugin };
}

fn arm(context: *anyopaque, kind: client.TimerKind, scheduler: *client.Scheduler) !void {
    const loop: *NativeLoop = @ptrCast(@alignCast(context));
    const inbox = &loop.inbox;

    switch (kind) {
        .input => try inbox.start(
            .input_timeout,
            .{
                client.wait,
                .{
                    loop.io,
                    scheduler,
                },
            },
        ),
        .binding => try inbox.start(
            .binding_timeout,
            .{
                client.wait,
                .{
                    loop.io,
                    scheduler,
                },
            },
        ),
        .bar => try inbox.start(
            .bar_tick,
            .{
                client.wait,
                .{
                    loop.io,
                    scheduler,
                },
            },
        ),
        .notification => try inbox.start(
            .notification_tick,
            .{
                client.wait,
                .{
                    loop.io,
                    scheduler,
                },
            },
        ),
        .sidebar_animation => try inbox.start(
            .sidebar_animation_tick,
            .{
                client.wait,
                .{
                    loop.io,
                    scheduler,
                },
            },
        ),
    }
}

fn startBar(context: *anyopaque, job: client.BarUpdatesJob) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.bar_command, .{ executeBar, .{ app.io, job } });
}

fn executeBar(io: std.Io, job: client.BarUpdatesJob) client.BarUpdatesCompletion {
    return .{ .execution_id = job.execution_id, .result = client.runBarCommand(io, job.command) };
}

fn startPlugin(context: *anyopaque, job: client.PluginActionsJob) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.plugin_result, .{ executePlugin, .{ app.io, app.gpa, job } });
}

fn executePlugin(io: std.Io, gpa: std.mem.Allocator, job: client.PluginActionsJob) client.PluginActionsCompletion {
    return .{ .execution_id = job.execution_id, .result = client.executeWorker(io, gpa, job.request) };
}

fn startPathCompletion(context: *anyopaque, job: client.PathCompletionJob) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.path_completion, .{ executePathCompletion, .{ app.io, app.gpa, job } });
}

fn startFavicon(context: *anyopaque, job: client.FaviconJob) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.favicon, .{ @import("../image/favicon_worker.zig").execute, .{ app.io, app.gpa, job } });
}

fn executePathCompletion(io: std.Io, gpa: std.mem.Allocator, job: client.PathCompletionJob) client.PathCompletionCompletion {
    return .{ .execution_id = job.execution_id, .result = client.runPathCompletion(io, gpa, job) };
}
