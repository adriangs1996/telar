/// Arms asynchronous infrastructure work and maps each completion to its
/// corresponding runtime event.
///
/// ```zig
/// var sources = Sources.init(io, select);
/// try sources.waitForAgentMaintenance();
/// ```
const Sources = @This();
const source_namespace = @import("event_sources.zig");
const transport = @import("../transport/root.zig");
const stop_signal_mod = @import("lifecycle/root.zig").stop_signal;
const StopScheduleContext = @import("StopScheduleContext.zig");
const history = @import("../history/root.zig");
const engine = @import("../engine/root.zig");
const proxy_resource = @import("resources/proxy.zig");
const ProxyScheduleContext = @import("ProxyScheduleContext.zig");
const ProxyCaptureScheduleContext = @import("ProxyCaptureScheduleContext.zig");
const plugins = @import("../plugins/root.zig");
io: source_namespace.Io,
select: *source_namespace.Io.Select(source_namespace.RuntimeEvent),

/// Borrows the runtime I/O implementation and event selector.
///
/// ```zig
/// var sources = Sources.init(io, select);
/// ```
pub fn init(io: source_namespace.Io, select: *source_namespace.Io.Select(source_namespace.RuntimeEvent)) Sources {
    return .{ .io = io, .select = select };
}

/// Arms the next local client admission.
///
/// ```zig
/// try sources.acceptClient(listener);
/// ```
pub fn acceptClient(sources: *Sources, listener: *transport.local.LocalListener) !void {
    try sources.select.concurrent(.accepted, source_namespace.awaitClient, .{ sources.io, listener });
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

/// Arms the next bounded effect batch from a tap worker.
///
/// ```zig
/// try sources.receivePluginEffects(plugin_service);
/// ```
pub fn receivePluginEffects(sources: *Sources, plugin_service: *plugins.Service) !void {
    try sources.select.concurrent(.plugin_effects, plugins.Service.receive, .{ plugin_service, sources.io });
}

/// Arms the next agent-maintenance tick.
///
/// ```zig
/// try sources.waitForAgentMaintenance();
/// ```
pub fn waitForAgentMaintenance(sources: *Sources) !void {
    try sources.select.concurrent(.agent_tick, source_namespace.waitForAgentTick, .{sources.io});
}

/// Arms the next system-metrics tick.
///
/// ```zig
/// try sources.waitForSystemMetrics();
/// ```
pub fn waitForSystemMetrics(sources: *Sources) !void {
    try sources.select.concurrent(.metrics_tick, source_namespace.waitForMetricsTick, .{sources.io});
}

/// Arms the next telemetry tick.
///
/// ```zig
/// try sources.waitForTelemetry();
/// ```
pub fn waitForTelemetry(sources: *Sources) !void {
    try sources.select.concurrent(.telemetry_tick, source_namespace.diagnostics.waitForTick, .{sources.io});
}
