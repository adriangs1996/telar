//! Composition root for one long-lived backend runtime.

const std = @import("std");
const agent_identity = @import("application/coordinators/root.zig").agent_identity;
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
pub const diagnostics = core.diagnostics;

pub const Options = runtime_config.Options;
pub const Initialization = runtime_config.Initialization;
pub const IngestTestGate = runtime_config.IngestTestGate;

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

pub const Application = runtime_application.Application;
pub const EventLoop = runtime_loop.Loop;
pub const Resources = runtime_resources.Resources;

pub const Runtime = @import("Runtime.zig");

const RuntimeShutdownCoordinator = runtime_shutdown_mod.Coordinator(Runtime);

pub fn runtimeShutdownCoordinator(runtime: *Runtime) RuntimeShutdownCoordinator {
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
        .destroy_plugins => runtime.resources.plugins.deinit(),
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
    return sleepLaunchIn(buffer, "/");
}

fn sleepLaunchIn(buffer: []u8, cwd: []const u8) !core.schema.LaunchView {
    var encoder = core.schema.wire.Encoder.init(buffer);
    try encoder.writeSized16("/bin/sleep");
    try encoder.writeSized16("600");
    return .{
        .cwd = cwd,
        .argument_count = 2,
        .encoded_arguments = encoder.finish(),
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

test "a restart drops tabs and workspaces whose panes did not come back" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/drop.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});
    var gone_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const gone = try std.fmt.bufPrint(&gone_buffer, "{s}/gone", .{directory});
    var other_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const other_directory = try std.fmt.bufPrint(&other_buffer, "{s}/other", .{directory});
    try temp.dir.createDir(io, "gone", .default_dir);
    try temp.dir.createDir(io, "other", .default_dir);
    const initialization: Initialization = .{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path },
    };

    var first: Runtime = undefined;
    try first.init(initialization);
    var repository = first.application.workspaceRepository();
    const kept = try repository.ensure(directory);
    var kept_buffer: [64]u8 = undefined;
    _ = try first.application.launchPane(.{
        .location = kept.location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&kept_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const logs_tab = try repository.nextTabId();
    _ = try repository.find(kept.location.workspace).?.createTab(logs_tab, "logs");
    repository.recordTabCreated(logs_tab);
    const logs_location: core.schema.TabLocation = .{ .workspace = kept.location.workspace, .tab_id = logs_tab };
    var logs_buffer: [64]u8 = undefined;
    _ = try first.application.launchPane(.{
        .location = logs_location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunchIn(&logs_buffer, gone),
        .launch_cwd = gone,
        .workspace_path = directory,
    });
    const dropped = try repository.ensure(other_directory);
    var dropped_buffer: [64]u8 = undefined;
    _ = try first.application.launchPane(.{
        .location = dropped.location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunchIn(&dropped_buffer, gone),
        .launch_cwd = gone,
        .workspace_path = other_directory,
    });
    first.deinit();
    try temp.dir.deleteDir(io, "gone");

    var second: Runtime = undefined;
    try second.init(initialization);
    defer second.deinit();
    const reader = second.application.workspaceReader();

    try std.testing.expect(!second.application.session.restore_failed);
    try std.testing.expectEqual(@as(u16, 1), second.application.session.restored_panes);
    try std.testing.expectEqual(@as(u16, 2), second.application.session.dropped_tabs);
    try std.testing.expect(reader.contains(kept.location));
    try std.testing.expect(!reader.contains(logs_location));
    try std.testing.expect(!reader.containsWorkspace(dropped.location.workspace));
    try std.testing.expectEqual(@as(usize, 1), reader.count());
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
    var main_buffer: [64]u8 = undefined;
    _ = try first.application.launchPane(.{
        .location = ensured.location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&main_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
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
        agent_identity.fromPane(pane),
        try agent_mod.SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
    ));
    try std.testing.expect(first.application.model.agents.observeProcess(.{
        .identity = agent_identity.fromPane(pane),
        .provider = .claude,
        .process_id = 99,
        .observed_at_ms = 1_000,
    }));
    try std.testing.expect(try first.application.model.agents.setManualTitle(pane.key(), "Investigate proxy lifecycle"));
    try std.testing.expect(first.application.session.dirty);
    first.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.application.session.writes);

    var second: Runtime = undefined;
    try second.init(initialization);
    defer second.deinit();
    const reader = second.application.workspaceReader();

    try std.testing.expect(!second.application.session.restore_failed);
    try std.testing.expectEqual(@as(u16, 1), second.application.session.restored_workspaces);
    try std.testing.expectEqual(@as(u16, 2), second.application.session.restored_panes);
    try std.testing.expectEqual(@as(u16, 0), second.application.session.dropped_tabs);
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
    try std.testing.expect(second.application.model.agents.observeProcess(.{
        .identity = agent_identity.fromPane(restored),
        .provider = .claude,
        .process_id = 100,
        .observed_at_ms = 2_000,
    }));
    var entries: [agent_mod.max_records]core.schema.AgentSnapshotEntry = undefined;
    const agents = second.application.model.agents.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), agents.len);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", agents[0].session_title);
    try std.testing.expectEqual(core.schema.AgentTitleSource.manual, agents[0].title_source);
    try std.testing.expectEqual(core.schema.AgentTitleState.ready, agents[0].title_state);
    try std.testing.expect(second.application.model.workspaces.next_tab_id > core.schema.id.raw(logs_tab));
}
