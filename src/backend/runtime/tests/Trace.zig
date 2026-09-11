const pane_resize_test = @import("pane_resize_test.zig");
const std = @import("std");
const Trace = @This();

effects: [8]pane_resize_test.Effect = undefined,
len: usize = 0,

pub fn record(trace: *Trace, effect: pane_resize_test.Effect) void {
    std.debug.assert(trace.len < trace.effects.len);
    trace.effects[trace.len] = effect;
    trace.len += 1;
}
