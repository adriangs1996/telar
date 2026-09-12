const JobType = @import("BarUpdatesJob.zig");
/// Runs one bar command on the adapter's event loop; its completion returns
/// as the adapter's own event.
const BarCommandRunner = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, JobType) anyerror!void,

/// Example: `try client.bar_runner.start(.{ .execution_id = id, .command = command });`.
pub fn start(port: BarCommandRunner, job: JobType) !void {
    return port.start_fn(port.context, job);
}
