const core = @import("telar-core");
const Dependencies = @import("../Dependencies.zig");
const std = @import("std");
const ChildEnvironment = @import("../../pty/ChildEnvironment.zig");
const ProxyRuntime = @import("ProxyRuntime.zig");
const LocalListener = @import("../../transport/LocalListener.zig");
const State = @import("../observability/State.zig");
const HistoryRuntime = @import("HistoryRuntime.zig");
const PluginsRuntime = @import("PluginsRuntime.zig");
const EngineRuntime = @import("EngineRuntime.zig");
const Initialization = @import("../Initialization.zig");
const resources_namespace = @import("resources_namespace.zig");
const attachment = @import("../attachment/attachment_namespace.zig");
const Service = @import("../../engine/Service.zig");
const PluginsService = @import("../../plugins/Service.zig");
/// Owns runtime-wide physical resources acquired during startup.
const Resources = @This();

dependencies: Dependencies,
heap: core.Heap,
gpa: std.mem.Allocator,
child_environment: ChildEnvironment,
/// Immutable after startup; observation workers borrow it by pointer.
agent_manifests: core.Table,
proxy: ProxyRuntime,
listener: LocalListener,
telemetry: State,
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
pub fn init(resources: *Resources, initialization: Initialization) !void {
    return resources.acquire(initialization, null);
}

pub fn acquire(resources: *Resources, initialization: Initialization, comptime fail_after: ?resources_namespace.AcquisitionPhase) !void {
    resources.dependencies = initialization.dependencies;
    resources.heap = core.Heap.init(initialization.dependencies.allocator);
    resources.gpa = resources.heap.allocator();

    try initialization.options.graphics.validate();
    attachment.initSharedFreezeNonce(resources.io());

    resources.agent_manifests = initialization.options.agent_manifests;
    resources.child_environment = try ChildEnvironment.init(resources.gpa, initialization.options.environment, "telar");
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

    resources.listener = try LocalListener.listen(resources.io(), initialization.options.endpoint);
    errdefer resources.listener.deinit(resources.io());
    try resources_namespace.checkpoint(fail_after, .listener);

    resources.telemetry = resources_namespace.initTelemetry(resources.io(), initialization.options.endpoint);
    errdefer resources.telemetry.deinit(resources.io());
    try resources_namespace.checkpoint(fail_after, .telemetry);

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
pub fn engineService(resources: *Resources) ?*Service {
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
    resources.telemetry.deinit(resources.io());
    resources.listener.deinit(resources.io());
    resources.child_environment.deinit();
}
