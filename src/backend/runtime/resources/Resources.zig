const core = @import("telar-core");
const Dependencies = @import("../Dependencies.zig");
const std = @import("std");
const pty = @import("pty");
const ChildEnvironment = pty.ChildEnvironment;
const ProxyRuntime = @import("ProxyRuntime.zig");
const localsocket = @import("localsocket");
const LocalListener = localsocket.LocalListener;
const State = @import("../observability/State.zig");
const HistoryRuntime = @import("HistoryRuntime.zig");
const PluginsRuntime = @import("PluginsRuntime.zig");
const EngineRuntime = @import("EngineRuntime.zig");
const Initialization = @import("../Initialization.zig");
const resources_namespace = @import("resources_namespace.zig");
const attachment = @import("../attachment/attachment_namespace.zig");
const Service = EngineRuntime.Service;
const PluginsService = @import("../../plugins/Service.zig");
const RuntimeLog = @import("RuntimeLog.zig");
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
/// The background runtime's standard error; empty in the foreground.
log: RuntimeLog,

/// Acquires physical resources in dependency order and rolls back every
/// completed acquisition if a later one fails.
///
/// ```zig
/// var resources: Resources = undefined;
/// try resources.init(initialization);
/// ```
pub fn init(self: *Resources, initialization: Initialization) !void {
    return self.acquire(initialization, null);
}

pub fn acquire(self: *Resources, initialization: Initialization, comptime fail_after: ?resources_namespace.AcquisitionPhase) !void {
    self.dependencies = initialization.dependencies;
    self.heap = core.Heap.init(initialization.dependencies.allocator);
    self.gpa = self.heap.allocator();

    try initialization.options.graphics.validate();
    attachment.initSharedFreezeNonce(self.io());

    self.agent_manifests = initialization.options.agent_manifests;
    self.child_environment = try ChildEnvironment.init(self.gpa, initialization.options.environment, "telar");
    errdefer self.child_environment.deinit();
    try resources_namespace.checkpoint(fail_after, .child_environment);

    self.proxy = try ProxyRuntime.init(
        self.io(),
        self.gpa,
        .{
            .config = initialization.options.proxy,
            .system_trusted = initialization.options.proxy_system_trusted,
        },
    );
    errdefer self.proxy.deinit();
    try resources_namespace.checkpoint(fail_after, .proxy);

    self.listener = try LocalListener.listen(self.io(), initialization.options.endpoint);
    errdefer self.listener.deinit(self.io());
    // Only the runtime holding the socket rotates its log, so a second
    // launch racing this one never moves a live runtime's log aside.
    self.log = if (initialization.options.own_log) RuntimeLog.open(self.io(), initialization.options.endpoint) else .{};
    try resources_namespace.checkpoint(fail_after, .listener);

    self.telemetry = resources_namespace.initTelemetry(self.io(), initialization.options.endpoint);
    errdefer self.telemetry.deinit(self.io());
    try resources_namespace.checkpoint(fail_after, .telemetry);

    self.history = try HistoryRuntime.init(self.io(), self.gpa, .{
        .database_path = initialization.options.history_path,
        .filters = initialization.options.history_filters,
        .capture_output = initialization.options.history_output_capture,
    });
    errdefer self.history.deinit();
    try resources_namespace.checkpoint(fail_after, .history);

    try self.plugins.init(.{
        .io = self.io(),
        .gpa = self.gpa,
        .specs = initialization.options.plugins,
    });
    errdefer self.plugins.deinit();
    try resources_namespace.checkpoint(fail_after, .plugins);

    self.engine = if (initialization.options.engine) |options|
        try EngineRuntime.init(self.io(), self.gpa, options)
    else
        null;
    errdefer if (self.engine) |*engine| engine.deinit();
    try resources_namespace.checkpoint(fail_after, .engine);
}

/// Borrows the engine service, or null when no engine is configured.
///
/// ```zig
/// const service = resources.engineService() orelse return;
/// ```
pub fn engineService(self: *Resources) ?*Service {
    if (self.engine) |*engine| {
        return engine.service();
    }

    return null;
}

pub fn pluginService(self: *Resources) *PluginsService {
    return self.plugins.service();
}

/// Returns the I/O implementation selected by the process root.
///
/// ```zig
/// const io = resources.io();
/// ```
pub fn io(self: *const Resources) std.Io {
    return self.dependencies.io;
}

/// Releases resources acquired before actors were started.
///
/// ```zig
/// resources.deinitUnstarted();
/// ```
pub fn deinitUnstarted(self: *Resources) void {
    if (self.engine) |*engine| {
        engine.deinit();
    }
    self.proxy.deinit();
    self.plugins.deinit();
    self.history.deinit();
    self.telemetry.deinit(self.io());
    self.listener.deinit(self.io());
    self.child_environment.deinit();
}
