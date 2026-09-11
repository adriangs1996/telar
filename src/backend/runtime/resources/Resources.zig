const DependenciesType = @import("../Dependencies.zig");
const HeapType = @import("telar-core").Heap;
const std = @import("std");
const ChildEnvironmentType = @import("../../pty/ChildEnvironment.zig");
const TableType = @import("telar-core").Table;
const ProxyRuntime = @import("ProxyRuntime.zig");
const LocalListenerType = @import("../../transport/LocalListener.zig");
const StateType = @import("../observability/State.zig");
const StoreType = @import("../client/Store.zig");
const HistoryRuntime = @import("HistoryRuntime.zig");
const PluginsRuntime = @import("PluginsRuntime.zig");
const EngineRuntime = @import("EngineRuntime.zig");
const InitializationType = @import("../Initialization.zig");
const resources_namespace = @import("resources_namespace.zig");
const attachment = @import("../attachment/attachment_namespace.zig");
const ServiceType = @import("../../engine/Service.zig");
const PluginsService = @import("../../plugins/Service.zig");
/// Owns runtime-wide physical resources acquired during startup.
const Resources = @This();

dependencies: DependenciesType,
heap: HeapType,
gpa: std.mem.Allocator,
child_environment: ChildEnvironmentType,
/// Immutable after startup; observation workers borrow it by pointer.
agent_manifests: TableType,
proxy: ProxyRuntime,
listener: LocalListenerType,
telemetry: StateType,
clients: *StoreType,
history: HistoryRuntime,
plugins: PluginsRuntime,
/// Present only when `runtime.engine` is configured.
engine: ?EngineRuntime,

/// Acquires physical resources in dependency order and rolls back every
/// completed acquisition if a later one fails.
///
/// ```zig
/// var resources: Resources = undefined;
/// try resources.init(initialization);
/// ```
pub fn init(resources: *Resources, initialization: InitializationType) !void {
    return resources.acquire(initialization, null);
}

pub fn acquire(resources: *Resources, initialization: InitializationType, comptime fail_after: ?resources_namespace.AcquisitionPhase) !void {
    resources.dependencies = initialization.dependencies;
    resources.heap = HeapType.init(initialization.dependencies.allocator);
    resources.gpa = resources.heap.allocator();

    try initialization.options.graphics.validate();
    attachment.initSharedFreezeNonce(resources.io());

    resources.agent_manifests = initialization.options.agent_manifests;
    resources.child_environment = try ChildEnvironmentType.init(resources.gpa, initialization.options.environment, "telar");
    errdefer resources.child_environment.deinit();
    try resources_namespace.checkpoint(fail_after, .child_environment);

    resources.proxy = try ProxyRuntime.init(
        resources.io(),
        resources.gpa,
        .{
            .config = initialization.options.proxy,
            .system_trusted = initialization.options.proxy_system_trusted,
        },
    );
    errdefer resources.proxy.deinit();
    try resources_namespace.checkpoint(fail_after, .proxy);

    resources.listener = try LocalListenerType.listen(resources.io(), initialization.options.endpoint);
    errdefer resources.listener.deinit(resources.io());
    try resources_namespace.checkpoint(fail_after, .listener);

    resources.telemetry = resources_namespace.initTelemetry(resources.io(), initialization.options.endpoint);
    errdefer resources.telemetry.deinit(resources.io());
    try resources_namespace.checkpoint(fail_after, .telemetry);

    resources.clients = try resources_namespace.createClientStore(resources.gpa);
    errdefer resources.gpa.destroy(resources.clients);
    try resources_namespace.checkpoint(fail_after, .clients);

    resources.history = try HistoryRuntime.init(resources.io(), resources.gpa, .{
        .database_path = initialization.options.history_path,
        .filters = initialization.options.history_filters,
        .capture_output = initialization.options.history_output_capture,
    });
    errdefer resources.history.deinit();
    try resources_namespace.checkpoint(fail_after, .history);

    try resources.plugins.init(.{
        .io = resources.io(),
        .gpa = resources.gpa,
        .specs = initialization.options.plugins,
    });
    errdefer resources.plugins.deinit();
    resources.proxy.setCaptureSink(.{
        .context = resources.plugins.service(),
        .submit_fn = resources_namespace.submitCapture,
    });
    try resources_namespace.checkpoint(fail_after, .plugins);

    resources.engine = if (initialization.options.engine) |options|
        try EngineRuntime.init(resources.io(), resources.gpa, options)
    else
        null;
    errdefer if (resources.engine) |*engine| engine.deinit();
    try resources_namespace.checkpoint(fail_after, .engine);
}

/// Borrows the engine service, or null when no engine is configured.
///
/// ```zig
/// const service = resources.engineService() orelse return;
/// ```
pub fn engineService(resources: *Resources) ?*ServiceType {
    if (resources.engine) |*engine| {
        return engine.service();
    }

    return null;
}

pub fn pluginService(resources: *Resources) *PluginsService {
    return resources.plugins.service();
}

/// Returns the I/O implementation selected by the process root.
///
/// ```zig
/// const io = resources.io();
/// ```
pub fn io(resources: *const Resources) std.Io {
    return resources.dependencies.io;
}

/// Releases resources acquired before actors were started.
///
/// ```zig
/// resources.deinitUnstarted();
/// ```
pub fn deinitUnstarted(resources: *Resources) void {
    if (resources.engine) |*engine| {
        engine.deinit();
    }
    resources.proxy.deinit();
    resources.plugins.deinit();
    resources.history.deinit();
    resources.gpa.destroy(resources.clients);
    resources.telemetry.deinit(resources.io());
    resources.listener.deinit(resources.io());
    resources.child_environment.deinit();
}
