//! Composition root for one long-lived backend runtime.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../workspace/root.zig");
const agent_mod = @import("../agent/root.zig");
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
        runtime.application.restoreSession();
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
            .engine_service = runtime.resources.engineService(),
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
            .socket_path = options.endpoint,
            .agent_manifests = &runtime.resources.agent_manifests,
            .session_path = options.session_path,
            .resume_agents = options.resume_agents,
            .proxy_runtime = &runtime.resources.proxy,
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
        .destroy_engine => if (runtime.resources.engine) |*engine_runtime| engine_runtime.deinit(),
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

fn sleepLaunch(buffer: []u8) !core.schema.LaunchView {
    var encoder = core.schema.wire.Encoder.init(buffer);
    try encoder.writeSized16("/bin/sleep");
    try encoder.writeSized16("600");
    return .{
        .cwd = "/",
        .argument_count = 2,
        .encoded_arguments = encoder.finish(),
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

test "a restart restores workspaces, tabs and panes from the session checkpoint" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/restart.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});
    const initialization: Initialization = .{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path },
    };

    var first: Runtime = undefined;
    try first.init(initialization);
    var repository = first.application.workspaceRepository();
    const ensured = try repository.ensure(directory);
    _ = try workspace_mod.renameWorkspace(&repository, ensured.location.workspace, "core");
    const logs_tab = try repository.nextTabId();
    _ = try repository.find(ensured.location.workspace).?.createTab(logs_tab, "logs");
    repository.recordTabCreated(logs_tab);
    var launch_buffer: [64]u8 = undefined;
    const pane = try first.application.launchPane(.{
        .location = .{ .workspace = ensured.location.workspace, .tab_id = logs_tab },
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&launch_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const pane_id = pane.id;
    const pane_generation = pane.generation;
    try std.testing.expect(first.application.model.agents.observeSessionReference(
        agent_mod.Identity.fromPane(pane),
        try agent_mod.SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
    ));
    try std.testing.expect(first.application.model.agents.observeProcess(.{
        .identity = agent_mod.Identity.fromPane(pane),
        .provider = .claude,
        .process_id = 99,
        .observed_at_ms = 1_000,
    }));
    try std.testing.expect(first.application.session.dirty);
    first.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.application.session.writes);

    var second: Runtime = undefined;
    try second.init(initialization);
    defer second.deinit();
    const reader = second.application.workspaceReader();

    try std.testing.expect(!second.application.session.restore_failed);
    try std.testing.expectEqual(@as(u16, 1), second.application.session.restored_workspaces);
    try std.testing.expectEqual(@as(u16, 1), second.application.session.restored_panes);
    try std.testing.expectEqualStrings("core", reader.workspaceName(ensured.location.workspace).?);
    try std.testing.expectEqualStrings("main", reader.tabLabel(ensured.location).?);
    try std.testing.expectEqualStrings("logs", reader.tabLabel(.{ .workspace = ensured.location.workspace, .tab_id = logs_tab }).?);
    const restored = second.application.model.panes.find(pane_id).?;
    try std.testing.expect(restored.generation > pane_generation);
    try std.testing.expectEqualStrings("/bin/sleep\x00600\x00", restored.launch_record.slice());
    try std.testing.expectEqual(@as(u16, 1), second.application.session.resumed_agents);
    try std.testing.expectEqualStrings(
        "claude --resume 0192aaaa-bbbb-cccc-dddd-eeeeffff0000\r",
        restored.input_queue.nextChunk().?,
    );
    try std.testing.expect(second.application.model.workspaces.next_tab_id > core.schema.id.raw(logs_tab));
}
