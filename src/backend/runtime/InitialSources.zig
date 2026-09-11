/// Owns the dependencies required to arm every initial runtime event source.
const InitialSources = @This();
const Sources = @import("Sources.zig");
const transport = @import("../transport/root.zig");
const stop_signal_mod = @import("lifecycle/root.zig").stop_signal;
const history = @import("../history/root.zig");
const engine = @import("../engine/root.zig");
const proxy_resource = @import("resources/proxy.zig");
const plugins = @import("../plugins/root.zig");
const source_namespace = @import("event_sources.zig");
sources: Sources,
listener: *transport.local.LocalListener,
stop_signal: *stop_signal_mod.Coordinator,
history_service: *history.Service,
engine_service: ?*engine.Service = null,
proxy_runtime: *proxy_resource.Runtime,
plugin_service: *plugins.Service,
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
    try initial_sources.sources.receivePluginEffects(initial_sources.plugin_service);
    try initial_sources.sources.waitForAgentMaintenance();
    try initial_sources.sources.waitForSystemMetrics();

    if (comptime source_namespace.diagnostics.enabled) {
        if (initial_sources.telemetry_available) {
            try initial_sources.sources.waitForTelemetry();
        }
    }
}
