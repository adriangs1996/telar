//! Starts the shared client's jobs as producers of the native inbox, outside
//! native callbacks.
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");

/// Starts one interactive job through the shared runner.
/// Example: `workers.start(gui, job) catch |err| try gui.app.failJob(job, err);`
pub fn start(gui: *GuiAdapter, job: client.Job) !void {
    const app = &gui.app;

    try gui.driver.inbox.start(.client, .{ client.job_runner.run, .{ app.io, job } });
}

/// A configuration watch also prepares the window's fonts, so its own
/// worker runs it; every other background job completes through the shared
/// runner.
/// Example: `workers.startBackground(gui, job) catch |err| try gui.app.failBackgroundJob(job, err);`
pub fn startBackground(gui: *GuiAdapter, job: client.BackgroundJob) !void {
    const app = &gui.app;
    const driver = &gui.driver;

    switch (job) {
        .config_watch => |args| try driver.configuration.schedule(args),
        else => try driver.inbox.start(.client, .{ client.job_runner.runBackground, .{ app.io, app.gpa, job } }),
    }
}
