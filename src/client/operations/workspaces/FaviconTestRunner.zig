//! A favicon runner for tests: records the last job instead of running it.
const JobType = @import("../../completion/FaviconJob.zig");
const FaviconTestRunner = @This();

started: usize = 0,
last: ?JobType = null,
fail: bool = false,

pub fn start(context: *anyopaque, job: JobType) !void {
    const runner: *FaviconTestRunner = @ptrCast(@alignCast(context));
    if (runner.fail) {
        return error.RunnerUnavailable;
    }

    runner.started += 1;
    runner.last = job;
}
