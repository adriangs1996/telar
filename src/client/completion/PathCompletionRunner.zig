const JobType = @import("PathCompletionJob.zig");
/// Runs one directory listing on the adapter's event loop; its completion
/// returns as the adapter's own event.
const PathCompletionRunner = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, JobType) anyerror!void,

/// Example: `try client.path_completion_runner.start(job);`.
pub fn start(port: PathCompletionRunner, job: JobType) !void {
    return port.start_fn(port.context, job);
}
