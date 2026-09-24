//! Scheduling boundary for infrastructure that produces runtime events.

const std = @import("std");
const localsocket = @import("localsocket");
const LocalListener = localsocket.LocalListener;

pub fn waitForAgentTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

pub fn waitForMetricsTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

pub fn awaitClient(io: std.Io, listener: *LocalListener) anyerror!localsocket.SocketChannel {
    return listener.accept(io);
}

test {
    std.testing.refAllDecls(@This());
}
