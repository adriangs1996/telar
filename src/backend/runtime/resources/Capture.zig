const worker_lifecycle = @import("worker_lifecycle.zig");
const std = @import("std");
const Capture = @This();

steps: [4]worker_lifecycle.Step = undefined,
len: usize = 0,
start_fails: bool = false,
closed: bool = false,
joined: bool = false,

pub fn record(capture: *Capture, step: worker_lifecycle.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}
