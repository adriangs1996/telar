const JobType = @import("FaviconJob.zig");
/// Runs one favicon lookup on the adapter's event loop; its completion
/// returns as the adapter's own event. Adapters without sprites leave the
/// client's runner unset and no lookup ever starts.
const FaviconRunner = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, JobType) anyerror!void,

/// Example: `try runner.start(job);`
pub fn start(port: FaviconRunner, job: JobType) !void {
    return port.start_fn(port.context, job);
}
