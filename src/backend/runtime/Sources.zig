const std = @import("std");
const event = @import("event.zig");
const LocalListenerType = @import("../transport/LocalListener.zig");
const event_sources = @import("event_sources.zig");
const StopSignalCoordinator = @import("lifecycle/StopSignalCoordinator.zig");
const StopScheduleContext = @import("StopScheduleContext.zig");
const ServiceType = @import("../history/Service.zig");
const EngineService = @import("../engine/Service.zig");
const ProxyRuntime = @import("resources/ProxyRuntime.zig");
const ProxyScheduleContext = @import("ProxyScheduleContext.zig");
const ProxyCaptureScheduleContext = @import("ProxyCaptureScheduleContext.zig");
const PluginsService = @import("../plugins/Service.zig");
const waitForTick_module = @import("telar-core").waitForTick;
/// Arms asynchronous infrastructure work and maps each completion to its
/// corresponding runtime event.
///
/// ```zig
/// var sources = Sources.init(io, select);
/// try sources.waitForAgentMaintenance();
/// ```
const Sources = @This();

io: std.Io,
select: *std.Io.Select(event.Event),

/// Borrows the runtime I/O implementation and event selector.
///
/// ```zig
/// var sources = Sources.init(io, select);
/// ```
pub fn init(io: std.Io, select: *std.Io.Select(event.Event)) Sources {
    return .{ .io = io, .select = select };
}

/// Arms the next local client admission.
///
/// ```zig
/// try sources.acceptClient(listener);
/// ```
pub fn acceptClient(sources: *Sources, listener: *LocalListenerType) !void {
    try sources.select.concurrent(.accepted, event_sources.awaitClient, .{ sources.io, listener });
}

/// Arms the optional external stop signal.
///
/// ```zig
/// try sources.waitForStop(stop_signal);
/// ```
pub fn waitForStop(sources: *Sources, stop_signal: *StopSignalCoordinator) !void {
    var context: StopScheduleContext = .{ .sources = sources };
    try stop_signal.arm(context.scheduler());
}

/// Arms the next history response receive.
///
/// ```zig
/// try sources.receiveHistory(history_service);
/// ```
pub fn receiveHistory(sources: *Sources, history_service: *ServiceType) !void {
    try sources.select.concurrent(.history_response, ServiceType.receiveResponse, .{ history_service, sources.io });
}

/// Arms the next engine reply receive.
///
/// ```zig
/// try sources.receiveEngine(engine_service);
/// ```
pub fn receiveEngine(sources: *Sources, engine_service: *EngineService) !void {
    try sources.select.concurrent(.engine_response, EngineService.receiveResponse, .{ engine_service, sources.io });
}

/// Arms the next proxy observation when the proxy is active.
///
/// ```zig
/// try sources.receiveProxyObservation(proxy_runtime);
/// ```
pub fn receiveProxyObservation(sources: *Sources, proxy_runtime: *ProxyRuntime) !void {
    var context: ProxyScheduleContext = .{ .sources = sources };
    try proxy_runtime.schedule(context.scheduler());
}

pub fn receiveProxyCapture(sources: *Sources, proxy_runtime: *ProxyRuntime) !void {
    var context: ProxyCaptureScheduleContext = .{ .sources = sources };
    try proxy_runtime.scheduleCapture(context.scheduler());
}

/// Arms the next bounded effect batch from a tap worker.
///
/// ```zig
/// try sources.receivePluginEffects(plugin_service);
/// ```
pub fn receivePluginEffects(sources: *Sources, plugin_service: *PluginsService) !void {
    try sources.select.concurrent(.plugin_effects, PluginsService.receive, .{ plugin_service, sources.io });
}

/// Arms the next agent-maintenance tick.
///
/// ```zig
/// try sources.waitForAgentMaintenance();
/// ```
pub fn waitForAgentMaintenance(sources: *Sources) !void {
    try sources.select.concurrent(.agent_tick, event_sources.waitForAgentTick, .{sources.io});
}

/// Arms the next system-metrics tick.
///
/// ```zig
/// try sources.waitForSystemMetrics();
/// ```
pub fn waitForSystemMetrics(sources: *Sources) !void {
    try sources.select.concurrent(.metrics_tick, event_sources.waitForMetricsTick, .{sources.io});
}

/// Arms the next telemetry tick.
///
/// ```zig
/// try sources.waitForTelemetry();
/// ```
pub fn waitForTelemetry(sources: *Sources) !void {
    try sources.select.concurrent(.telemetry_tick, waitForTick_module, .{sources.io});
}
