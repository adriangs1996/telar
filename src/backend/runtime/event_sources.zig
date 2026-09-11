//! Scheduling boundary for infrastructure that produces runtime events.

const std = @import("std");
const core = @import("telar-core");
const engine = @import("../engine/root.zig");
const history = @import("../history/root.zig");
const proxy_mod = @import("../proxy/root.zig");
const plugins = @import("../plugins/root.zig");
const transport = @import("../transport/root.zig");
const runtime_event = @import("event.zig");
const stop_signal_mod = @import("lifecycle/root.zig").stop_signal;
const proxy_resource = @import("resources/proxy.zig");

pub const Io = std.Io;
pub const RuntimeEvent = runtime_event.Event;
pub const diagnostics = core.diagnostics;

pub const Sources = @import("Sources.zig");

pub const InitialSources = @import("InitialSources.zig");

const StopScheduleContext = @import("StopScheduleContext.zig");

const ProxyScheduleContext = @import("ProxyScheduleContext.zig");

const ProxyCaptureScheduleContext = @import("ProxyCaptureScheduleContext.zig");

pub fn waitForAgentTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

pub fn waitForMetricsTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

pub fn awaitClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    return listener.accept(io);
}

test {
    std.testing.refAllDecls(@This());
}
