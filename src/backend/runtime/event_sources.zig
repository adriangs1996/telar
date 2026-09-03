//! Scheduling boundary for infrastructure that produces runtime events.

const std = @import("std");
const core = @import("telar-core");
const engine = @import("../engine/root.zig");
const history = @import("../history/root.zig");
const proxy_mod = @import("../proxy/root.zig");
const transport = @import("../transport/root.zig");
const runtime_event = @import("event.zig");
const stop_signal_mod = @import("lifecycle/root.zig").stop_signal;
const proxy_resource = @import("resources/proxy.zig");

const Io = std.Io;
const RuntimeEvent = runtime_event.Event;
const diagnostics = core.diagnostics;

/// Arms asynchronous infrastructure work and maps each completion to its
/// corresponding runtime event.
///
/// ```zig
/// var sources = Sources.init(io, select);
/// try sources.waitForAgentMaintenance();
/// ```
pub const Sources = struct {
    io: Io,
    select: *Io.Select(RuntimeEvent),

    /// Borrows the runtime I/O implementation and event selector.
    ///
    /// ```zig
    /// var sources = Sources.init(io, select);
    /// ```
    pub fn init(io: Io, select: *Io.Select(RuntimeEvent)) Sources {
        return .{ .io = io, .select = select };
    }

    /// Arms the next local client admission.
    ///
    /// ```zig
    /// try sources.acceptClient(listener);
    /// ```
    pub fn acceptClient(sources: *Sources, listener: *transport.local.LocalListener) !void {
        try sources.select.concurrent(.accepted, awaitClient, .{ sources.io, listener });
    }

    /// Arms the optional external stop signal.
    ///
    /// ```zig
    /// try sources.waitForStop(stop_signal);
    /// ```
    pub fn waitForStop(sources: *Sources, stop_signal: *stop_signal_mod.Coordinator) !void {
        var context: StopScheduleContext = .{ .sources = sources };
        try stop_signal.arm(context.scheduler());
    }

    /// Arms the next history response receive.
    ///
    /// ```zig
    /// try sources.receiveHistory(history_service);
    /// ```
    pub fn receiveHistory(sources: *Sources, history_service: *history.Service) !void {
        try sources.select.concurrent(.history_response, history.Service.receiveResponse, .{ history_service, sources.io });
    }

    /// Arms the next engine reply receive.
    ///
    /// ```zig
    /// try sources.receiveEngine(engine_service);
    /// ```
    pub fn receiveEngine(sources: *Sources, engine_service: *engine.Service) !void {
        try sources.select.concurrent(.engine_response, engine.Service.receiveResponse, .{ engine_service, sources.io });
    }

    /// Arms the next proxy observation when the proxy is active.
    ///
    /// ```zig
    /// try sources.receiveProxyObservation(proxy_runtime);
    /// ```
    pub fn receiveProxyObservation(sources: *Sources, proxy_runtime: *proxy_resource.Runtime) !void {
        var context: ProxyScheduleContext = .{ .sources = sources };
        try proxy_runtime.schedule(context.scheduler());
    }

    pub fn receiveProxyCapture(sources: *Sources, proxy_runtime: *proxy_resource.Runtime) !void {
        var context: ProxyCaptureScheduleContext = .{ .sources = sources };
        try proxy_runtime.scheduleCapture(context.scheduler());
    }

    /// Arms the next agent-maintenance tick.
    ///
    /// ```zig
    /// try sources.waitForAgentMaintenance();
    /// ```
    pub fn waitForAgentMaintenance(sources: *Sources) !void {
        try sources.select.concurrent(.agent_tick, waitForAgentTick, .{sources.io});
    }

    /// Arms the next system-metrics tick.
    ///
    /// ```zig
    /// try sources.waitForSystemMetrics();
    /// ```
    pub fn waitForSystemMetrics(sources: *Sources) !void {
        try sources.select.concurrent(.metrics_tick, waitForMetricsTick, .{sources.io});
    }

    /// Arms the next telemetry tick.
    ///
    /// ```zig
    /// try sources.waitForTelemetry();
    /// ```
    pub fn waitForTelemetry(sources: *Sources) !void {
        try sources.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{sources.io});
    }
};

/// Owns the dependencies required to arm every initial runtime event source.
pub const InitialSources = struct {
    sources: Sources,
    listener: *transport.local.LocalListener,
    stop_signal: *stop_signal_mod.Coordinator,
    history_service: *history.Service,
    engine_service: ?*engine.Service = null,
    proxy_runtime: *proxy_resource.Runtime,
    telemetry_available: bool,

    /// Arms every source that may produce the runtime's first event.
    ///
    /// ```zig
    /// try initial_sources.schedule();
    /// ```
    pub fn schedule(initial_sources: *InitialSources) !void {
        try initial_sources.sources.acceptClient(initial_sources.listener);
        try initial_sources.sources.waitForStop(initial_sources.stop_signal);
        try initial_sources.sources.receiveHistory(initial_sources.history_service);
        if (initial_sources.engine_service) |engine_service| {
            try initial_sources.sources.receiveEngine(engine_service);
        }
        try initial_sources.sources.receiveProxyObservation(initial_sources.proxy_runtime);
        try initial_sources.sources.receiveProxyCapture(initial_sources.proxy_runtime);
        try initial_sources.sources.waitForAgentMaintenance();
        try initial_sources.sources.waitForSystemMetrics();

        if (comptime diagnostics.enabled) {
            if (initial_sources.telemetry_available) {
                try initial_sources.sources.waitForTelemetry();
            }
        }
    }
};

const StopScheduleContext = struct {
    sources: *Sources,

    fn scheduler(context: *StopScheduleContext) stop_signal_mod.Scheduler {
        return .{ .context = context, .schedule_fn = schedule };
    }

    fn schedule(context_value: *anyopaque, queue: *Io.Queue(u8)) !void {
        const context: *StopScheduleContext = @ptrCast(@alignCast(context_value));
        try context.sources.select.concurrent(.stopped, stop_signal_mod.wait, .{ context.sources.io, queue });
    }
};

const ProxyScheduleContext = struct {
    sources: *Sources,

    fn scheduler(context: *ProxyScheduleContext) proxy_resource.ObservationScheduler {
        return .{ .context = context, .schedule_fn = schedule };
    }

    fn schedule(context_value: *anyopaque, proxy: *proxy_mod.Proxy) !void {
        const context: *ProxyScheduleContext = @ptrCast(@alignCast(context_value));
        try context.sources.select.concurrent(.proxy_event, proxy_mod.Proxy.receive, .{ proxy, context.sources.io });
    }
};

const ProxyCaptureScheduleContext = struct {
    sources: *Sources,

    fn scheduler(context: *ProxyCaptureScheduleContext) proxy_resource.CaptureScheduler {
        return .{ .context = context, .schedule_fn = schedule };
    }

    fn schedule(context_value: *anyopaque, proxy: *proxy_mod.Proxy) !void {
        const context: *ProxyCaptureScheduleContext = @ptrCast(@alignCast(context_value));
        try context.sources.select.concurrent(.proxy_capture, proxy_mod.Proxy.receiveCapture, .{ proxy, context.sources.io });
    }
};

fn waitForAgentTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

fn waitForMetricsTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

fn awaitClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    return listener.accept(io);
}

test {
    std.testing.refAllDecls(@This());
}
