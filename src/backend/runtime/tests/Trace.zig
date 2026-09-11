const Trace = @This();
const source_namespace = @import("pane_resize_test.zig");
const std = @import("std");
effects: [8]source_namespace.Effect = undefined,
len: usize = 0,

pub fn record(trace: *Trace, effect: source_namespace.Effect) void {
    std.debug.assert(trace.len < trace.effects.len);
    trace.effects[trace.len] = effect;
    trace.len += 1;
}
