const core = @import("telar-core");
const std = @import("std");
const event = @import("event.zig");
const LocalListener = @import("../transport/LocalListener.zig");
const event_sources = @import("event_sources.zig");
const HistoryService = @import("../history/Service.zig");
const EngineRuntime = @import("resources/EngineRuntime.zig");
const EngineService = EngineRuntime.Service;
const Proxy = @import("../proxy/Proxy.zig");
const ProxyRuntime = @import("resources/ProxyRuntime.zig");
const PluginsService = @import("../plugins/Service.zig");
const stop_signal = @import("lifecycle/stop_signal.zig");
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

/// Arms the optional external stop signal. Without a queue this arms
/// nothing and the runtime stops only through its clients.
///
/// ```zig
/// try sources.waitForStop(options.stop);
/// ```
pub fn waitForStop(self: *Sources, queue: ?*std.Io.Queue(u8)) !void {
    const stop = queue orelse return;
    try self.select.concurrent(.stopped, stop_signal.wait, .{ self.io, stop });
}

/// Arms the next history response receive.
///
/// ```zig
/// try sources.receiveHistory(history_service);
/// ```
pub fn receiveHistory(self: *Sources, history_service: *HistoryService) !void {
    try self.select.concurrent(.history_response, HistoryService.receiveResponse, .{ history_service, self.io });
}

/// Arms the next engine reply receive.
///
/// ```zig
/// try sources.receiveEngine(engine_service);
/// ```
pub fn receiveEngine(self: *Sources, engine_service: *EngineService) !void {
    try self.select.concurrent(.engine_response, EngineService.receiveResponse, .{ engine_service, self.io });
}

/// Arms the next proxy observation. A disabled proxy arms nothing.
///
/// ```zig
/// try sources.receiveProxyObservation(&resources.proxy);
/// ```
pub fn receiveProxyObservation(self: *Sources, proxy_runtime: *ProxyRuntime) !void {
    const proxy = proxy_runtime.capability() orelse return;
    try self.select.concurrent(.proxy_event, Proxy.receive, .{ proxy, self.io });
}

/// Arms the next captured exchange half. A disabled proxy arms nothing.
///
/// ```zig
/// try sources.receiveProxyCapture(&resources.proxy);
/// ```
pub fn receiveProxyCapture(self: *Sources, proxy_runtime: *ProxyRuntime) !void {
    const proxy = proxy_runtime.capability() orelse return;
    try self.select.concurrent(.proxy_capture, Proxy.receiveCapture, .{ proxy, self.io });
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

const ProxyTestFiles = @import("resources/ProxyTestFiles.zig");

fn unavailableSources(storage: *[1]event.Event, select: *std.Io.Select(event.Event)) Sources {
    select.* = .init(std.Io.failing, storage);
    return .{ .io = std.testing.io, .select = select };
}

test "a disabled stop signal and a disabled proxy arm nothing" {
    var storage: [1]event.Event = undefined;
    var select: std.Io.Select(event.Event) = undefined;
    var sources = unavailableSources(&storage, &select);
    var proxy = try ProxyRuntime.init(std.testing.io, std.testing.allocator, .{ .config = null, .system_trusted = true });
    defer proxy.deinit();

    try sources.waitForStop(null);
    try sources.receiveProxyObservation(&proxy);
    try sources.receiveProxyCapture(&proxy);
}

test "an armed stop signal and an active proxy propagate scheduling failures" {
    var storage: [1]event.Event = undefined;
    var select: std.Io.Select(event.Event) = undefined;
    var sources = unavailableSources(&storage, &select);
    var queue_storage: [1]u8 = undefined;
    var queue: std.Io.Queue(u8) = .init(&queue_storage);
    var files = try ProxyTestFiles.init(std.testing.io);
    defer files.deinit();
    var proxy = try ProxyRuntime.init(std.testing.io, std.testing.allocator, .{ .config = files.config(), .system_trusted = false });
    defer proxy.deinit();

    try std.testing.expectError(error.ConcurrencyUnavailable, sources.waitForStop(&queue));
    try std.testing.expectError(error.ConcurrencyUnavailable, sources.receiveProxyObservation(&proxy));
    try std.testing.expectError(error.ConcurrencyUnavailable, sources.receiveProxyCapture(&proxy));
    try std.testing.expect(proxy.active());
}

test "an armed stop signal completes with its queue token" {
    const io = std.testing.io;
    var storage: [1]event.Event = undefined;
    var select: std.Io.Select(event.Event) = .init(io, &storage);
    var sources = Sources.init(io, &select);
    var queue_storage: [1]u8 = undefined;
    var queue: std.Io.Queue(u8) = .init(&queue_storage);

    try sources.waitForStop(&queue);
    try queue.putOne(io, 7);
    const completed = try select.await();
    try std.testing.expect(completed == .stopped);
    try completed.stopped;
}
