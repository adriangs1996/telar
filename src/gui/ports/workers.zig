//! Bounded shared-client jobs run as inbox producers, outside native callbacks.
const favicon_worker = @import("../image/favicon_worker.zig");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");

/// Starts every shared client job as a producer of the native inbox.
/// Example: `app.workers = workers.jobs(app);`
pub fn jobs(app: *client.AttachedClient) client.Workers {
    return .{ .context = app, .start_fn = startJob };
}

/// Example: `app.favicon_runner = workers.favicons(app);`
pub fn favicons(app: *client.AttachedClient) client.FaviconRunner {
    return .{ .context = app, .start_fn = startFavicon };
}

fn startJob(context: *anyopaque, job: client.Job) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));

    try GuiClient.of(app).driver.inbox.start(.client, .{ client.job_runner.run, .{ app.io, app.gpa, job } });
}

fn startFavicon(context: *anyopaque, job: client.FaviconJob) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.favicon, .{ favicon_worker.execute, .{ app.io, app.gpa, job } });
}
