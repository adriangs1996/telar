//! Scheduling boundary for infrastructure that produces runtime events.

const core = @import("telar-core");
const std = @import("std");
const LocalListener = @import("../transport/LocalListener.zig");

pub fn waitForAgentTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

pub fn waitForMetricsTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

pub fn awaitClient(io: std.Io, listener: *LocalListener) anyerror!core.SocketChannel {
    return listener.accept(io);
}

test {
    std.testing.refAllDecls(@This());
}
