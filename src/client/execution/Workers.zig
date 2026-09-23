//! Runs client jobs on the adapter's event loop. The adapter owns the inbox;
//! the jobs and their completions belong to the shared client.
const std = @import("std");
const Job = @import("Job.zig").Job;
const Workers = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, Job) anyerror!void,

/// Example: `try client.workers.start(.{ .link = target });`
pub fn start(self: Workers, job: Job) !void {
    return self.start_fn(self.context, job);
}

test {
    std.testing.refAllDecls(@This());
}
