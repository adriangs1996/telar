const Sources = @import("Sources.zig");
const LocalListenerType = @import("../transport/LocalListener.zig");
const StopSignalCoordinator = @import("lifecycle/StopSignalCoordinator.zig");
const ServiceType = @import("../history/Service.zig");
const EngineService = @import("../engine/Service.zig");
const ProxyRuntime = @import("resources/ProxyRuntime.zig");
const PluginsService = @import("../plugins/Service.zig");
const enabled_module = @import("telar-core").enabled;
/// Owns the dependencies required to arm every initial runtime event source.
const InitialSources = @This();

sources: Sources,
listener: *LocalListenerType,
stop_signal: *StopSignalCoordinator,
history_service: *ServiceType,
engine_service: ?*EngineService = null,
proxy_runtime: *ProxyRuntime,
plugin_service: *PluginsService,
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

    if (comptime enabled_module) {
        if (initial_sources.telemetry_available) {
            try initial_sources.sources.waitForTelemetry();
        }
    }
}
