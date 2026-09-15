//! Composition root for one long-lived backend runtime.

const std = @import("std");
const Options = @import("Options.zig");
const Runtime = @import("Runtime.zig");
const GenericShutdownCoordinator = @import("lifecycle/GenericShutdownCoordinator.zig").Type;
const runtime_shutdown_mod = @import("lifecycle/shutdown_coordinator.zig");
const LaunchViewType = @import("telar-core").LaunchView;
const EncoderType = @import("telar-core").Encoder;
const Initialization = @import("Initialization.zig");
const TabLocationType = @import("telar-core").TabLocation;
const commands = @import("../workspace/commands.zig");
const agent_identity = @import("application/coordinators/agent_identity.zig");
const SessionReferenceType = @import("../agent/SessionReference.zig");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const raw_module = @import("telar-core").raw;
const PersistenceEncoder = @import("../persistence/Encoder.zig");
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const encodeClientLayoutUpdate = @import("telar-core").encodeClientLayoutUpdate;
const decodeClient = @import("telar-core").decodeClient;

/// Runs one runtime instance until a stop event or fatal runtime error.
/// `options` is borrowed for the duration of the call.
///
/// ```zig
/// try serve(io, gpa, .{
///     .endpoint = "/tmp/telar.sock",
///     .environment = environment,
/// });
/// ```
pub fn serve(io: std.Io, gpa: std.mem.Allocator, options: Options) !void {
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = gpa },
        .options = options,
    });
    defer runtime.deinit();

    try runtime.run();
}

const RuntimeShutdownCoordinator = GenericShutdownCoordinator(Runtime);

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
        .persist_session => runtime.application.shutdownStep(.persist_session),
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

fn expectRuntimeEndpointRemoved(io: std.Io, endpoint: []const u8) !void {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
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

fn sleepLaunch(buffer: []u8) !LaunchViewType {
    return sleepLaunchIn(buffer, "/");
}

fn sleepLaunchIn(buffer: []u8, cwd: []const u8) !LaunchViewType {
    var encoder = EncoderType.init(buffer);
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
    const logs_location: TabLocationType = .{ .workspace = kept.location.workspace, .tab_id = logs_tab };
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
    _ = try commands.renameWorkspace(&repository, ensured.location.workspace, "core");
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
        try SessionReferenceType.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
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
    try std.testing.expectEqualStrings("", reader.tabLabel(ensured.location).?);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const agents = second.application.model.agents.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), agents.len);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", agents[0].session_title);
    try std.testing.expectEqual(AgentTitleSourceType.manual, agents[0].title_source);
    try std.testing.expectEqual(AgentTitleStateType.ready, agents[0].title_state);
    try std.testing.expect(second.application.model.workspaces.next_tab_id > raw_module(logs_tab));
}

test "a restart restores every workspace and tab from unordered pane records" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/unordered.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});

    var buffer: [4096]u8 = undefined;
    var encoder = try PersistenceEncoder.init(&buffer, .{
        .next_workspace_id = 3,
        .next_tab_id = 4,
        .next_pane_id = 5,
        .next_pane_generation = 9,
    });
    try encoder.workspace(.{ .id = 1, .path = directory, .name = "core", .first_tab_id = 1, .first_tab_label = "main" });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 2, .label = "logs" });
    try encoder.workspace(.{ .id = 2, .path = directory, .name = "api", .first_tab_id = 3, .first_tab_label = "agent" });

    var tabs: [3]ClientTabLayoutType = undefined;
    var nodes: [3]ClientLayoutNodeType = undefined;
    // A replacement occupies the first free slot, ahead of surviving panes.
    for ([_]u64{ 4, 2, 3 }, 0..) |pane_id, index| {
        try encoder.pane(.{
            .pane_id = pane_id,
            .workspace_id = if (index == 2) 2 else 1,
            .tab_id = index + 1,
            .cwd = directory,
            .cols = 20,
            .rows = 5,
            .arguments = "/bin/sleep\x00600\x00",
            .argument_count = 2,
        });
        nodes[index] = .{ .pane = .{ .id = @enumFromInt(pane_id) } };
        tabs[index] = .{
            .location = .{ .workspace = .{ .workspace = @enumFromInt(if (index == 2) @as(u64, 2) else 1) }, .tab_id = @enumFromInt(index + 1) },
            .focused_pane = @enumFromInt(pane_id),
            .fullscreen = false,
            .workspace_active = index != 0,
            .nodes = nodes[index .. index + 1],
        };
    }

    var layout_buffer: [1024]u8 = undefined;
    try encoder.layout(.{ .identity = 42, .last_used = 1, .payload = try encodeClientLayoutUpdate(&layout_buffer, .{
        .sidebar_visible = true,
        .sidebar_width = 27,
        .workspace_list_collapsed = false,
        .active_tab = tabs[1].location,
        .tabs = &tabs,
    }) });

    try temp.dir.writeFile(io, .{ .sub_path = "session.ckpt", .data = try encoder.finish() });
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path },
    });
    defer runtime.deinit();
    const reader = runtime.application.workspaceReader();

    try std.testing.expect(!runtime.application.session.restore_failed);
    try std.testing.expectEqual(@as(u16, 3), runtime.application.session.restored_panes);
    try std.testing.expectEqual(@as(u16, 0), runtime.application.session.dropped_tabs);
    try std.testing.expectEqual(@as(usize, 2), reader.count());
    for ([_]u64{ 4, 2, 3 }, 0..) |pane_id, index| {
        const pane = runtime.application.model.panes.find(@enumFromInt(pane_id)).?;
        try std.testing.expectEqual(@as(u64, index + 1), raw_module(pane.location.tab_id));
        try std.testing.expect(pane.generation >= 9);
        try std.testing.expect(reader.contains(pane.location));
    }

    const exported = (try runtime.application.model.client_layouts.exportRecord(0, &layout_buffer)).?;
    const restored_layout = (try decodeClient(exported.payload)).update_client_layout;
    try std.testing.expectEqual(@as(u16, 27), restored_layout.sidebar_width);
    try std.testing.expectEqual(tabs[1].location, restored_layout.active_tab);
    var restored_tabs = restored_layout.tabs();
    for (tabs) |tab| {
        try std.testing.expectEqual(tab.location, (try restored_tabs.next()).?.location);
    }
    try std.testing.expect(try restored_tabs.next() == null);
}

test "repeated restarts preserve pending agent resumes and reject duplicate sessions" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/pending.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});
    const reference = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";

    var buffer: [4096]u8 = undefined;
    var encoder = try PersistenceEncoder.init(&buffer, .{ .next_workspace_id = 2, .next_tab_id = 3, .next_pane_id = 3, .next_pane_generation = 3 });
    try encoder.workspace(.{ .id = 1, .path = directory, .name = "", .first_tab_id = 1, .first_tab_label = "agent" });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 2, .label = "duplicate" });
    for ([_]u64{ 1, 2 }) |id| {
        try encoder.pane(.{
            .pane_id = id,
            .workspace_id = 1,
            .tab_id = id,
            .cwd = directory,
            .cols = 20,
            .rows = 5,
            .arguments = "/bin/sleep\x00600\x00",
            .argument_count = 2,
            .agent_provider = @intFromEnum(@import("telar-core").AgentProvider.claude),
            .agent_session = reference,
            .agent_title = "Preserve pending resume",
            .agent_title_source = @intFromEnum(AgentTitleSourceType.manual),
        });
    }

    try temp.dir.writeFile(io, .{ .sub_path = "session.ckpt", .data = try encoder.finish() });
    for (0..3) |_| {
        var runtime: Runtime = undefined;
        try runtime.init(.{
            .dependencies = .{ .io = io, .allocator = std.testing.allocator },
            .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path },
        });
        defer runtime.deinit();
        try std.testing.expectEqual(@as(u16, 2), runtime.application.session.restored_panes);
        try std.testing.expectEqual(@as(u16, 1), runtime.application.session.resumed_agents);
        const pane = runtime.application.model.panes.find(@enumFromInt(1)).?;
        try std.testing.expectEqualStrings("claude --resume " ++ reference ++ "\r", pane.input_queue.nextChunk().?);
        try std.testing.expectEqualStrings(reference, runtime.application.model.agents.resumeSession(pane.key()).?.reference.slice());
        try std.testing.expectEqualStrings("Preserve pending resume", runtime.application.model.agents.checkpointTitle(pane.key()).?.slice());
        try std.testing.expect(runtime.application.model.panes.find(@enumFromInt(2)).?.input_queue.nextChunk() == null);
        var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
        try std.testing.expectEqual(@as(usize, 0), runtime.application.model.agents.snapshot(&entries, 0).len);
    }
}

test "direct agent restore launches resume argv and preserves the original command for disabled resume" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/direct.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try std.fmt.bufPrint(&executable_buffer, "{s}/claude", .{directory});
    var script = try temp.dir.createFile(io, "claude", .{ .permissions = std.Io.File.Permissions.fromMode(0o700) });
    try script.writeStreamingAll(io, "#!/bin/sh\nprintf '%s\\n' \"$@\" > arguments.tmp\n/bin/mv arguments.tmp arguments\nexec /bin/sleep 600\n");
    script.close(io);
    const reference = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";

    var argument_buffer: [2048]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&argument_buffer, "{s}\x00original-option\x00", .{executable});
    var buffer: [4096]u8 = undefined;
    var encoder = try PersistenceEncoder.init(&buffer, .{ .next_workspace_id = 2, .next_tab_id = 2, .next_pane_id = 2, .next_pane_generation = 2 });
    try encoder.workspace(.{ .id = 1, .path = directory, .name = "", .first_tab_id = 1, .first_tab_label = "agent" });
    try encoder.pane(.{
        .pane_id = 1,
        .workspace_id = 1,
        .tab_id = 1,
        .cwd = directory,
        .cols = 20,
        .rows = 5,
        .arguments = arguments,
        .argument_count = 2,
        .agent_provider = @intFromEnum(@import("telar-core").AgentProvider.claude),
        .agent_session = reference,
    });
    try temp.dir.writeFile(io, .{ .sub_path = "session.ckpt", .data = try encoder.finish() });

    for ([_]bool{ true, false }) |resume_agents| {
        var runtime: Runtime = undefined;
        try runtime.init(.{
            .dependencies = .{ .io = io, .allocator = std.testing.allocator },
            .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path, .resume_agents = resume_agents },
        });
        defer runtime.deinit();
        const pane = runtime.application.model.panes.find(@enumFromInt(1)).?;
        try std.testing.expectEqualStrings(arguments, pane.launch_record.slice());
        try std.testing.expect(pane.input_queue.nextChunk() == null);
        try std.testing.expectEqual(@as(u16, if (resume_agents) 1 else 0), runtime.application.session.resumed_agents);
        const actual = try awaitArguments(temp.dir);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(if (resume_agents) "--resume\n" ++ reference ++ "\n" else "original-option\n", actual);
        try temp.dir.deleteFile(io, "arguments");
    }
}

fn awaitArguments(directory: std.Io.Dir) ![]u8 {
    for (0..200) |_| {
        const bytes = directory.readFileAlloc(std.testing.io, "arguments", std.testing.allocator, .limited(256)) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        return bytes;
    }

    return error.AgentLaunchTimeout;
}

test "process observation checkpoints a session reported before provider detection and its later exit" {
    const application_namespace = @import("application/application_namespace.zig");
    const pane_namespace = @import("../pane/pane_namespace.zig");
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/observed.sock", .{directory});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.fmt.bufPrint(&session_buffer, "{s}/session.ckpt", .{directory});
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = session_path },
    });
    defer runtime.deinit();
    var repository = runtime.application.workspaceRepository();
    const workspace = try repository.ensure(directory);
    var argument_buffer: [64]u8 = undefined;
    const pane = try runtime.application.launchPane(.{
        .location = workspace.location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunchIn(&argument_buffer, directory),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    try std.testing.expect(runtime.application.model.agents.observeSessionReference(agent_identity.fromPane(pane), try SessionReferenceType.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100)));
    try std.testing.expect(runtime.application.model.agents.resumeSession(pane.key()) == null);

    for ([_]bool{ true, false }) |agent_foreground| {
        application_namespace.SessionCheckpoint.writeNow(&runtime.application);
        try std.testing.expect(!runtime.application.session.dirty);
        pane.queueHistoryOutput(.{ .bytes = "observed", .shell_foreground = false, .clock = pane_namespace.historyClock(io) });
        try std.testing.expect(pane.beginHistoryObservation() != null);
        const shell_id: u32 = @intCast(pane.session.processId());
        _ = try application_namespace.RuntimeEvents.handle(&runtime.application, .{ .pane_observed = .{
            .pane = pane.key(),
            .stats = .{},
            .process_probe = .{
                .cache = .{ .process_group_id = if (agent_foreground) shell_id + 1 else shell_id, .provider = if (agent_foreground) .claude else .unknown },
                .changed = true,
                .inspected = true,
            },
        } }, .{ .listener = &runtime.resources.listener, .telemetry = &runtime.resources.telemetry, .ingest_gate = null });
        try std.testing.expect(runtime.application.session.dirty);
        try std.testing.expectEqual(agent_foreground, runtime.application.model.agents.resumeSession(pane.key()) != null);
    }
}
