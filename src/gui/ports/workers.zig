//! Bounded shared-client jobs run as inbox producers, outside native callbacks.
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");

/// Starts every shared client job as a producer of the native inbox.
/// Example: `gui.app.workers = workers.jobs(gui);`
pub fn jobs(gui: *GuiClient) client.Workers {
    return .{ .context = gui, .start_fn = startJob };
}

/// A configuration watch also prepares the window's fonts, so its own
/// worker runs it; every other job completes through the shared runner.
fn startJob(context: *anyopaque, job: client.Job) !void {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    const app = &gui.app;
    const driver = &gui.driver;

    switch (job) {
        .config_watch => |args| try driver.configuration.schedule(args),
        else => try driver.inbox.start(.client, .{ client.job_runner.run, .{ app.io, app.gpa, job } }),
    }
}
