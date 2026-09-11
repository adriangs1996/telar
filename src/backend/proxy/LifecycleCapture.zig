const lifecycle = @import("lifecycle.zig");
const std = @import("std");
const Capture = @This();

steps: [4]lifecycle.Step = undefined,
len: usize = 0,
start_fails: bool = false,
canceled: bool = false,
closed: bool = false,
destroyed: bool = false,

pub fn record(capture: *Capture, step: lifecycle.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}
