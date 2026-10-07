const core = @import("telar-core");
const std = @import("std");
const event = @import("event.zig");
const localsocket = @import("localsocket");
const LocalListener = localsocket.LocalListener;
const event_sources = @import("event_sources.zig");
const HistoryService = @import("../history/Service.zig");
const EngineRuntime = @import("resources/EngineRuntime.zig");
const EngineService = EngineRuntime.Service;
const Proxy = @import("../proxy/Proxy.zig");
const ProxyRuntime = @import("resources/ProxyRuntime.zig");
const PluginsService = @import("../plugins/Service.zig");
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
pub fn acceptClient(self: *Sources, listener: *LocalListener) !void {
    try self.select.concurrent(.accepted, event_sources.awaitClient, .{ self.io, listener });
}

/// Arms the next history response receive.
///
/// ```zig
/// try sources.receiveHistory(history_service);
/// ```
pub fn receiveHistory(self: *Sources, history_service: *HistoryService) !void {
    try self.select.concurrent(.history_response, HistoryService.receiveResponse, .{ history_service, self.io });
}

/// Arms the next engine reply receive. The reply lands in `slot`, which the
/// loop reads once the event arrives, so a kilobytes-long reply never
/// widens every event the loop can queue.
///
/// ```zig
/// try sources.receiveEngine(engine_service, &model.engine_reply);
/// ```
pub fn receiveEngine(self: *Sources, engine_service: *EngineService, slot: *EngineService.Response) !void {
    try self.select.concurrent(.engine_response, receiveEngineReply, .{ engine_service, self.io, slot });
}

fn receiveEngineReply(engine_service: *EngineService, io: std.Io, slot: *EngineService.Response) anyerror!void {
    slot.* = try engine_service.receiveResponse(io);
}

/// Arms the next captured exchange half. A disabled proxy arms nothing.
///
/// ```zig
/// try sources.receiveProxyCapture(&resources.proxy, resources.pluginService());
/// ```
pub fn receiveProxyCapture(self: *Sources, proxy_runtime: *ProxyRuntime, tap: *const PluginsService) !void {
    const proxy = proxy_runtime.capability() orelse return;
    try self.select.concurrent(.proxy_capture, Proxy.receiveCapture, .{ proxy, self.io, tap.listening() });
}

/// Arms the next bounded effect batch from a tap worker.
///
/// ```zig
/// try sources.receivePluginEffects(plugin_service);
/// ```
pub fn receivePluginEffects(self: *Sources, plugin_service: *PluginsService) !void {
    try self.select.concurrent(.plugin_effects, PluginsService.receive, .{ plugin_service, self.io });
}

/// Arms the next agent-maintenance tick.
///
/// ```zig
/// try sources.waitForAgentMaintenance();
/// ```
pub fn waitForAgentMaintenance(self: *Sources) !void {
    try self.select.concurrent(.agent_tick, event_sources.waitForAgentTick, .{self.io});
}

/// Arms the next system-metrics tick.
///
/// ```zig
/// try sources.waitForSystemMetrics();
/// ```
pub fn waitForSystemMetrics(self: *Sources) !void {
    try self.select.concurrent(.metrics_tick, event_sources.waitForMetricsTick, .{self.io});
}

/// Arms the next telemetry tick.
///
/// ```zig
/// try sources.waitForTelemetry();
/// ```
pub fn waitForTelemetry(self: *Sources) !void {
    try self.select.concurrent(.telemetry_tick, core.waitForTick, .{self.io});
}
