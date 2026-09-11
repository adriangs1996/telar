const TestingScheduler = @This();

fail: bool = false,

// The signature implements std.Io.Select.concurrent for failure injection.
// codestyle: allow(maximum-parameter-count)
pub fn concurrent(scheduler: *TestingScheduler, tag: anytype, function: anytype, args: anytype) !void {
    _ = tag;
    _ = function;
    _ = args;
    if (scheduler.fail) {
        return error.SchedulerUnavailable;
    }
}
