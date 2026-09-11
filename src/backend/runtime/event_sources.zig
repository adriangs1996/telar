//! Scheduling boundary for infrastructure that produces runtime events.

const std = @import("std");
const LocalListenerType = @import("../transport/LocalListener.zig");
const SocketChannelType = @import("telar-core").SocketChannel;

pub fn waitForAgentTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

pub fn waitForMetricsTick(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

pub fn awaitClient(io: std.Io, listener: *LocalListenerType) anyerror!SocketChannelType {
    return listener.accept(io);
}

test {
    std.testing.refAllDecls(@This());
}
