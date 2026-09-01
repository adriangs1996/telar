//! Composition root for one long-lived backend runtime.

const std = @import("std");
const core = @import("telar-core");
const runtime_application = @import("application/root.zig");
const runtime_config = @import("config.zig");
const runtime_event = @import("event.zig");
const event_sources = @import("event_sources.zig");
const runtime_loop = @import("event_loop.zig");
const runtime_shutdown_mod = @import("lifecycle/root.zig").shutdown_coordinator;
const runtime_resources = @import("resources/root.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;

const Options = runtime_config.Options;
const Initialization = runtime_config.Initialization;
const IngestTestGate = runtime_config.IngestTestGate;

/// Runs one runtime instance until a stop event or fatal runtime error.
/// `options` is borrowed for the duration of the call.
///
/// ```zig
/// try serve(io, gpa, .{
///     .endpoint = "/tmp/telar.sock",
///     .environment = environment,
/// });
/// ```
pub fn serve(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = gpa },
        .options = options,
    });
    defer runtime.deinit();

    try runtime.run();
}

const Application = runtime_application.Application;
const EventLoop = runtime_loop.Loop;
const Resources = runtime_resources.Resources;

/// Owns and composes the resources, event loop and application for one
/// long-lived backend lifetime.
pub const Runtime = struct {
    resources: Resources,
    loop: EventLoop,
    application: Application,
    ingest_gate: ?*IngestTestGate,
    teardown_state: runtime_shutdown_mod.State,

    /// Acquires all runtime-owned resources. The caller must keep `runtime` at
    /// the same address until `deinit` completes.
    ///
    /// ```zig
    /// var runtime: Runtime = undefined;
    /// try runtime.init(.{ .dependencies = dependencies, .options = options });
    /// defer runtime.deinit();
    /// ```
    pub fn init(runtime: *Runtime, initialization: Initialization) !void {
        try runtime.start(initialization, false);
    }

    fn start(runtime: *Runtime, initialization: Initialization, comptime fail_after_actors: bool) !void {
        runtime.ingest_gate = initialization.options.ingest_gate;
        runtime.teardown_state = .running;

        try runtime.resources.init(initialization);
        errdefer runtime.resources.deinitUnstarted();

        runtime.loop.init(runtime.resources.io(), initialization.options.stop);
        errdefer runtime.loop.cancel();

        runtime.application = try runtime.composeApplication(initialization.options);
        errdefer runtime.application.model.client_layouts.deinit();
        try runtime.scheduleInitialEvents();

        if (comptime fail_after_actors) {
            return error.InjectedStartupFailure;
        }
    }

    fn scheduleInitialEvents(runtime: *Runtime) !void {
        var initial_sources: event_sources.InitialSources = .{
            .sources = event_sources.Sources.init(runtime.resources.io(), runtime.loop.selector()),
            .listener = &runtime.resources.listener,
            .stop_signal = runtime.loop.stopCoordinator(),
            .history_service = runtime.resources.history.service(),
            .proxy_runtime = &runtime.resources.proxy,
            .telemetry_available = runtime.resources.telemetry.available(),
        };

        try initial_sources.schedule();
    }

    fn composeApplication(runtime: *Runtime, options: Options) !Application {
        return Application.init(.{
            .io = runtime.resources.io(),
            .gpa = runtime.resources.gpa,
            .heap = &runtime.resources.heap,
            .select = runtime.loop.selector(),
            .history_service = runtime.resources.history.service(),
            .child_environment = &runtime.resources.child_environment,
            .inherited_environment = options.environment,
            .proxy_runtime = &runtime.resources.proxy,
            .agent_description_options = options.agent_descriptions,
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
            const path = diagnostics.enter(runtime_event.diagnosticsPath(event));
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
        var shutdown = runtimeShutdownCoordinator(runtime);
        shutdown.run();
    }
};

const RuntimeShutdownCoordinator = runtime_shutdown_mod.Coordinator(Runtime);

fn runtimeShutdownCoordinator(runtime: *Runtime) RuntimeShutdownCoordinator {
    return RuntimeShutdownCoordinator.init(runtime, &runtime.teardown_state, executeRuntimeShutdownStep);
}

fn executeRuntimeShutdownStep(runtime: *Runtime, step: runtime_shutdown_mod.Step) void {
    switch (step) {
        .stop_listener => runtime.resources.listener.shutdown(),
        .stop_client_connections => runtime.application.shutdownStep(.stop_client_connections),
        .stop_pending_admission => runtime.application.shutdownStep(.stop_pending_admission),
        .stop_panes => runtime.application.shutdownStep(.stop_panes),
        .cancel_actors => runtime.loop.cancel(),
        .destroy_proxy => runtime.resources.proxy.deinit(),
        .destroy_listener => runtime.resources.listener.deinit(runtime.resources.io()),
        .destroy_pending_admission => runtime.application.shutdownStep(.destroy_pending_admission),
        .release_client_actor_claims => runtime.application.shutdownStep(.release_client_actor_claims),
        .destroy_client_sessions => runtime.application.shutdownStep(.destroy_client_sessions),
        .destroy_panes => runtime.application.shutdownStep(.destroy_panes),
        .destroy_workspaces => runtime.application.shutdownStep(.destroy_workspaces),
        .destroy_history => runtime.resources.history.deinit(),
        .destroy_client_store => runtime.resources.gpa.destroy(runtime.resources.clients),
        .destroy_telemetry => runtime.resources.telemetry.deinit(runtime.resources.io()),
        .destroy_child_environment => runtime.resources.child_environment.deinit(),
    }
}

fn expectRuntimeEndpointRemoved(io: Io, endpoint: []const u8) !void {
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
    );
}

test "invalid graphics limits fail before runtime resources are created" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/invalid.sock", .{directory_buffer[0..directory_len]});
    var runtime: Runtime = undefined;

    try std.testing.expectError(error.InvalidGraphicsLimits, runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{
            .endpoint = endpoint,
            .environment = std.testing.environ,
            .graphics = .{ .pane_bytes = 1 },
        },
    }));
    try expectRuntimeEndpointRemoved(io, endpoint);
}

test "a failure after actor scheduling rolls back the composed runtime" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/actor-startup.sock", .{directory_buffer[0..directory_len]});
    var runtime: Runtime = undefined;

    try std.testing.expectError(error.InjectedStartupFailure, runtime.start(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
    }, true));
    try expectRuntimeEndpointRemoved(io, endpoint);
}

test "runtime composition keeps every borrowed capability at a stable address" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/composed.sock", .{directory_buffer[0..directory_len]});
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
    });

    try std.testing.expect(runtime.application.heap == &runtime.resources.heap);
    try std.testing.expect(runtime.application.select == runtime.loop.selector());
    try std.testing.expect(runtime.application.history_service == runtime.resources.history.service());
    try std.testing.expect(runtime.application.child_environment == &runtime.resources.child_environment);
    try std.testing.expect(runtime.application.proxy_runtime == &runtime.resources.proxy);
    try std.testing.expect(runtime.application.clients == runtime.resources.clients);

    runtime.deinit();
    runtime.deinit();
    try expectRuntimeEndpointRemoved(io, endpoint);
}
