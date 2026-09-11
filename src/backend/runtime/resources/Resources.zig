/// Owns runtime-wide physical resources acquired during startup.
const Resources = @This();
const config = @import("../config.zig");
const source_namespace = @import("root.zig");
const std = @import("std");
const pty = @import("../../pty/root.zig");
const core = @import("telar-core");
const proxy_runtime = @import("proxy.zig");
const transport = @import("../../transport/root.zig");
const telemetry_module = @import("../observability/root.zig").telemetry;
const client_store = @import("../client/root.zig").store;
const history_runtime = @import("history.zig");
const plugins_runtime = @import("plugins.zig");
const engine_runtime = @import("engine.zig");
const attachment = @import("../attachment/root.zig");
dependencies: config.Dependencies,
heap: source_namespace.diagnostics.Heap,
gpa: std.mem.Allocator,
child_environment: pty.ChildEnvironment,
/// Immutable after startup; observation workers borrow it by pointer.
agent_manifests: core.agent_manifest.Table,
proxy: proxy_runtime.Runtime,
listener: transport.local.LocalListener,
telemetry: telemetry_module.State,
clients: *client_store.Store,
history: history_runtime.Runtime,
plugins: plugins_runtime.Runtime,
/// Present only when `runtime.engine` is configured.
engine: ?engine_runtime.Runtime,

/// Acquires physical resources in dependency order and rolls back every
/// completed acquisition if a later one fails.
///
/// ```zig
/// var resources: Resources = undefined;
/// try resources.init(initialization);
/// ```
pub fn init(resources: *Resources, initialization: config.Initialization) !void {
    return resources.acquire(initialization, null);
}

pub fn acquire(resources: *Resources, initialization: config.Initialization, comptime fail_after: ?source_namespace.AcquisitionPhase) !void {
    resources.dependencies = initialization.dependencies;
    resources.heap = source_namespace.diagnostics.Heap.init(initialization.dependencies.allocator);
    resources.gpa = resources.heap.allocator();

    try initialization.options.graphics.validate();
    attachment.initSharedFreezeNonce(resources.io());

    resources.agent_manifests = initialization.options.agent_manifests;
    resources.child_environment = try pty.ChildEnvironment.init(resources.gpa, initialization.options.environment, "telar");
    errdefer resources.child_environment.deinit();
    try source_namespace.checkpoint(fail_after, .child_environment);

    resources.proxy = try proxy_runtime.Runtime.init(
        resources.io(),
        resources.gpa,
        .{
            .config = initialization.options.proxy,
            .system_trusted = initialization.options.proxy_system_trusted,
        },
    );
    errdefer resources.proxy.deinit();
    try source_namespace.checkpoint(fail_after, .proxy);

    resources.listener = try transport.local.LocalListener.listen(resources.io(), initialization.options.endpoint);
    errdefer resources.listener.deinit(resources.io());
    try source_namespace.checkpoint(fail_after, .listener);

    resources.telemetry = source_namespace.initTelemetry(resources.io(), initialization.options.endpoint);
    errdefer resources.telemetry.deinit(resources.io());
    try source_namespace.checkpoint(fail_after, .telemetry);

    resources.clients = try source_namespace.createClientStore(resources.gpa);
    errdefer resources.gpa.destroy(resources.clients);
    try source_namespace.checkpoint(fail_after, .clients);

    resources.history = try history_runtime.Runtime.init(resources.io(), resources.gpa, .{
        .database_path = initialization.options.history_path,
        .filters = initialization.options.history_filters,
        .capture_output = initialization.options.history_output_capture,
    });
    errdefer resources.history.deinit();
    try source_namespace.checkpoint(fail_after, .history);

    try resources.plugins.init(.{
        .io = resources.io(),
        .gpa = resources.gpa,
        .specs = initialization.options.plugins,
    });
    errdefer resources.plugins.deinit();
    resources.proxy.setCaptureSink(.{
        .context = resources.plugins.service(),
        .submit_fn = source_namespace.submitCapture,
    });
    try source_namespace.checkpoint(fail_after, .plugins);

    resources.engine = if (initialization.options.engine) |options|
        try engine_runtime.Runtime.init(resources.io(), resources.gpa, options)
    else
        null;
    errdefer if (resources.engine) |*engine| engine.deinit();
    try source_namespace.checkpoint(fail_after, .engine);
}

/// Borrows the engine service, or null when no engine is configured.
///
/// ```zig
/// const service = resources.engineService() orelse return;
/// ```
pub fn engineService(resources: *Resources) ?*engine_runtime.Runtime.Service {
    if (resources.engine) |*engine| {
        return engine.service();
    }

    return null;
}

pub fn pluginService(resources: *Resources) *@import("../../plugins/root.zig").Service {
    return resources.plugins.service();
}

/// Returns the I/O implementation selected by the process root.
///
/// ```zig
/// const io = resources.io();
/// ```
pub fn io(resources: *const Resources) source_namespace.Io {
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
