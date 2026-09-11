const Capture = @This();
const source_namespace = @import("worker_lifecycle.zig");
const std = @import("std");
steps: [4]source_namespace.Step = undefined,
len: usize = 0,
start_fails: bool = false,
closed: bool = false,
joined: bool = false,

pub fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}
