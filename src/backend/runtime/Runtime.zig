const ResourcesType = @import("resources/Resources.zig");
const Loop = @import("Loop.zig");
const ApplicationType = @import("application/Application.zig");
const IngestTestGateType = @import("IngestTestGate.zig");
const runtime_shutdown_mod = @import("lifecycle/shutdown_coordinator.zig");
const InitializationType = @import("Initialization.zig");
const InitialSourcesType = @import("InitialSources.zig");
const SourcesType = @import("Sources.zig");
const OptionsType = @import("Options.zig");
const enter_module = @import("telar-core").enter;
const runtime_event = @import("event.zig");
const runtime_application = @import("application/application_namespace.zig");
const instance = @import("instance.zig");
/// Owns and composes the resources, event loop and application for one
/// long-lived backend lifetime.
const Runtime = @This();

resources: ResourcesType,
loop: Loop,
application: ApplicationType,
ingest_gate: ?*IngestTestGateType,
teardown_state: runtime_shutdown_mod.State,

/// Acquires all runtime-owned resources. The caller must keep `runtime` at
/// the same address until `deinit` completes.
///
/// ```zig
/// var runtime: Runtime = undefined;
/// try runtime.init(.{ .dependencies = dependencies, .options = options });
/// defer runtime.deinit();
/// ```
pub fn init(runtime: *Runtime, initialization: InitializationType) !void {
    try runtime.start(initialization, false);
}

pub fn start(runtime: *Runtime, initialization: InitializationType, comptime fail_after_actors: bool) !void {
    runtime.ingest_gate = initialization.options.ingest_gate;
    runtime.teardown_state = .running;

    try runtime.resources.init(initialization);
    errdefer runtime.resources.deinitUnstarted();

    runtime.loop.init(runtime.resources.io(), initialization.options.stop);
    errdefer runtime.loop.cancel();

    runtime.application = try runtime.composeApplication(initialization.options);
    errdefer runtime.application.model.client_layouts.deinit();
    runtime.application.restoreSession();
    try runtime.scheduleInitialEvents();

    if (comptime fail_after_actors) {
        return error.InjectedStartupFailure;
    }
}

fn scheduleInitialEvents(runtime: *Runtime) !void {
    var initial_sources: InitialSourcesType = .{
        .sources = SourcesType.init(runtime.resources.io(), runtime.loop.selector()),
        .listener = &runtime.resources.listener,
        .stop_signal = runtime.loop.stopCoordinator(),
        .history_service = runtime.resources.history.service(),
        .engine_service = runtime.resources.engineService(),
        .proxy_runtime = &runtime.resources.proxy,
        .plugin_service = runtime.resources.pluginService(),
        .telemetry_available = runtime.resources.telemetry.available(),
    };

    try initial_sources.schedule();
}

fn composeApplication(runtime: *Runtime, options: OptionsType) !ApplicationType {
    return ApplicationType.init(.{
        .io = runtime.resources.io(),
        .gpa = runtime.resources.gpa,
        .heap = &runtime.resources.heap,
        .select = runtime.loop.selector(),
        .history_service = runtime.resources.history.service(),
        .child_environment = &runtime.resources.child_environment,
        .inherited_environment = options.environment,
        .socket_path = options.endpoint,
        .agent_manifests = &runtime.resources.agent_manifests,
        .session_path = options.session_path,
        .resume_agents = options.resume_agents,
        .proxy_runtime = &runtime.resources.proxy,
        .plugin_service = runtime.resources.pluginService(),
        .agent_description_options = options.agent_descriptions,
        .engine_service = runtime.resources.engineService(),
        .launch_fault = options.launch_fault,
        .clients = runtime.resources.clients,
        .graphics = options.graphics,
    });
}

/// Runs the event loop until the runtime receives a stop event or an
/// infrastructure failure escapes an event entrypoint.
///
/// ```zig
/// try runtime.run();
/// ```
pub fn run(runtime: *Runtime) !void {
    while (true) {
        const event = try runtime.loop.next();
        const path = enter_module(runtime_event.diagnosticsPath(event));
        defer path.restore();

        switch (event) {
            .stopped => |result| if (try runtime.loop.completeStop(result)) {
                return;
            },
            else => {
                const should_stop = try runtime_application.handle(&runtime.application, event, .{
                    .listener = &runtime.resources.listener,
                    .telemetry = &runtime.resources.telemetry,
                    .ingest_gate = runtime.ingest_gate,
                });

                if (should_stop) {
                    return;
                }
            },
        }
    }
}

/// Stops actors and releases acquired resources in dependency order. It is
/// safe to call again after teardown has completed.
///
/// ```zig
/// runtime.deinit();
/// ```
pub fn deinit(runtime: *Runtime) void {
    var shutdown = instance.runtimeShutdownCoordinator(runtime);
    shutdown.run();
}
