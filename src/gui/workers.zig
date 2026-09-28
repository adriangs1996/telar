//! Starts the shared client's jobs as producers of the native inbox, outside
//! native callbacks.
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const MachineMessage = @import("MachineMessage.zig");
const std = @import("std");

/// Starts one interactive job through the shared runner.
/// Example: `workers.start(gui, job) catch |err| try gui.app.failJob(job, err);`
pub fn start(gui: *GuiAdapter, job: client.Job) !void {
    const app = gui.app;

    try gui.driver.inbox.start(.client, .{ client.job_runner.run, .{ app.io, job } });
}

/// A configuration watch also prepares the window's fonts, so its own
/// worker runs it; every other background job completes through the shared
/// runner.
/// Example: `workers.startBackground(gui, job) catch |err| try gui.app.failBackgroundJob(job, err);`
pub fn startBackground(gui: *GuiAdapter, job: client.BackgroundJob) !void {
    const app = gui.app;
    const driver = &gui.driver;

    switch (job) {
        .config_watch => |args| try driver.configuration.schedule(args),
        else => try driver.inbox.start(.client, .{ client.job_runner.runBackground, .{ app.io, app.gpa, job } }),
    }
}

/// Starts one interactive job of the client in `slot`, whose completion
/// comes back tagged with that slot.
/// Example: `workers.startFor(gui, slot, job) catch |err| try gui.clients[slot].failJob(job, err);`
pub fn startFor(gui: *GuiAdapter, slot: u8, job: client.Job) !void {
    const app = &gui.clients[slot];
    try gui.driver.inbox.start(.machine, .{ runOn, .{ app.io, slot, job } });
}

/// Starts one background job of the client in `slot`, as `startFor`.
/// Example: `workers.startBackgroundFor(gui, slot, job) catch |err| try gui.clients[slot].failBackgroundJob(job, err);`
pub fn startBackgroundFor(gui: *GuiAdapter, slot: u8, job: client.BackgroundJob) !void {
    const app = &gui.clients[slot];
    try gui.driver.inbox.start(.machine, .{ runBackgroundOn, .{ app.io, app.gpa, slot, job } });
}

fn runOn(io: std.Io, slot: u8, job: client.Job) MachineMessage {
    return .{
        .slot = slot,
        .message = client.job_runner.run(io, job),
    };
}

fn runBackgroundOn(io: std.Io, gpa: std.mem.Allocator, slot: u8, job: client.BackgroundJob) MachineMessage {
    return .{
        .slot = slot,
        .message = client.job_runner.runBackground(io, gpa, job),
    };
}
