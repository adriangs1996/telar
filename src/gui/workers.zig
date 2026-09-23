//! Starts the shared client's jobs as producers of the native inbox, outside
//! native callbacks.
const client = @import("telar-client");
const GuiClient = @import("GuiClient.zig");

/// A configuration watch also prepares the window's fonts, so its own
/// worker runs it; every other job completes through the shared runner.
/// Example: `workers.start(gui, job) catch |err| try gui.app.failJob(job, err);`
pub fn start(gui: *GuiClient, job: client.Job) !void {
    const app = &gui.app;
    const driver = &gui.driver;

    switch (job) {
        .config_watch => |args| try driver.configuration.schedule(args),
        else => try driver.inbox.start(.client, .{ client.job_runner.run, .{ app.io, app.gpa, job } }),
    }
}
