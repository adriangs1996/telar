const JobType = @import("PluginActionsJob.zig");
/// Runs one plugin worker on the adapter's event loop; its completion returns
/// as the adapter's own event.
const PluginWorkerRunner = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, JobType) anyerror!void,

/// Example: `try client.plugin_runner.start(.{ .execution_id = id, .request = request });`.
pub fn start(port: PluginWorkerRunner, job: JobType) !void {
    return port.start_fn(port.context, job);
}
