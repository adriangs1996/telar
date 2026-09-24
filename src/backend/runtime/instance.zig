//! Composition root for one long-lived backend runtime.

const bytecodec = @import("bytecodec");
const session_checkpoint = @import("session_checkpoint.zig");
const pane_launch = @import("pane_launch.zig");
const core = @import("telar-core");
const std = @import("std");
const Options = @import("Options.zig");
const Runtime = @import("Runtime.zig");
const Initialization = @import("Initialization.zig");
const agent_identity = @import("agent_identity.zig");
const SessionReference = @import("../agent/SessionReference.zig");
const PersistenceEncoder = @import("../persistence/Encoder.zig");

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

    try std.testing.expect(runtime.model.resources == &runtime.resources);
    try std.testing.expect(runtime.model.select == runtime.loop.selector());

    runtime.deinit();
    try std.testing.expectEqual(.stopped, runtime.teardown_state);
    runtime.deinit();
    try std.testing.expectEqual(.stopped, runtime.teardown_state);
    try expectRuntimeEndpointRemoved(io, endpoint);
}

fn sleepLaunch(buffer: []u8) !core.LaunchView {
    return sleepLaunchIn(buffer, "/");
}

fn sleepLaunchIn(buffer: []u8, cwd: []const u8) !core.LaunchView {
    var encoder = bytecodec.Encoder.init(buffer);
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
    const workspaces = &first.model.workspaces;
    const gpa = first.model.gpa;
    const kept = try workspaces.insert(gpa, directory, null);
    var kept_buffer: [64]u8 = undefined;
    _ = try pane_launch.launch(&first.model, .{
        .location = kept,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&kept_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const logs_tab = try workspaces.nextTabId();
    _ = try workspaces.addTab(workspaces.slotOf(kept.workspace).?, logs_tab, "logs");
    workspaces.recordTabCreated(logs_tab);
    const logs_location: core.TabLocation = .{ .workspace = kept.workspace, .tab_id = logs_tab };
    var logs_buffer: [64]u8 = undefined;
    _ = try pane_launch.launch(&first.model, .{
        .location = logs_location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunchIn(&logs_buffer, gone),
        .launch_cwd = gone,
        .workspace_path = directory,
    });
    const dropped = try workspaces.insert(gpa, other_directory, null);
    var dropped_buffer: [64]u8 = undefined;
    _ = try pane_launch.launch(&first.model, .{
        .location = dropped,
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
    const reader = &second.model.workspaces;

    try std.testing.expect(!second.model.checkpoint.restore_failed);
    try std.testing.expectEqual(@as(u16, 1), second.model.checkpoint.restored_panes);
    try std.testing.expectEqual(@as(u16, 2), second.model.checkpoint.dropped_tabs);
    try std.testing.expect(reader.contains(kept));
    try std.testing.expect(!reader.contains(logs_location));
    try std.testing.expect(!reader.containsWorkspace(dropped.workspace));
    try std.testing.expectEqual(@as(usize, 1), reader.count);
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
    const workspaces = &first.model.workspaces;
    const gpa = first.model.gpa;
    const ensured = try workspaces.insert(gpa, directory, null);
    var main_buffer: [64]u8 = undefined;
    _ = try pane_launch.launch(&first.model, .{
        .location = ensured,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&main_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    try workspaces.rename(ensured.workspace, "core");
    const logs_tab = try workspaces.nextTabId();
    _ = try workspaces.addTab(workspaces.slotOf(ensured.workspace).?, logs_tab, "logs");
    workspaces.recordTabCreated(logs_tab);
    var launch_buffer: [64]u8 = undefined;
    const pane = try pane_launch.launch(&first.model, .{
        .location = .{ .workspace = ensured.workspace, .tab_id = logs_tab },
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&launch_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const pane_id = pane.id;
    const pane_generation = pane.generation;
    try std.testing.expect(first.model.agents.observeSessionReference(
        agent_identity.fromPane(pane),
        try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
    ));
    try std.testing.expect(first.model.agents.observeProcess(.{
        .identity = agent_identity.fromPane(pane),
        .provider = .claude,
        .process_id = 99,
        .observed_at_ms = 1_000,
    }));
    try std.testing.expect(try first.model.agents.setManualTitle(pane.key(), "Investigate proxy lifecycle"));
    try std.testing.expect(first.model.checkpoint.dirty);
    first.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.model.checkpoint.writes);

    var second: Runtime = undefined;
    try second.init(initialization);
    defer second.deinit();
    const reader = &second.model.workspaces;

    try std.testing.expect(!second.model.checkpoint.restore_failed);
    try std.testing.expectEqual(@as(u16, 1), second.model.checkpoint.restored_workspaces);
    try std.testing.expectEqual(@as(u16, 2), second.model.checkpoint.restored_panes);
    try std.testing.expectEqual(@as(u16, 0), second.model.checkpoint.dropped_tabs);
    try std.testing.expectEqualStrings("core", reader.workspaceName(ensured.workspace).?);
    try std.testing.expectEqualStrings("", reader.tabLabel(ensured).?);
    try std.testing.expectEqualStrings("logs", reader.tabLabel(.{ .workspace = ensured.workspace, .tab_id = logs_tab }).?);
    const restored = second.model.panes.find(pane_id).?;
    try std.testing.expect(restored.generation > pane_generation);
    try std.testing.expectEqualStrings("/bin/sleep\x00600\x00", restored.launch_record.slice());
    try std.testing.expectEqual(@as(u16, 1), second.model.checkpoint.resumed_agents);
    try std.testing.expectEqualStrings(
        "claude --resume 0192aaaa-bbbb-cccc-dddd-eeeeffff0000\r",
        restored.input_queue.nextChunk().?,
    );
    try std.testing.expect(second.model.agents.observeProcess(.{
        .identity = agent_identity.fromPane(restored),
        .provider = .claude,
        .process_id = 100,
        .observed_at_ms = 2_000,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const agents = second.model.agents.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), agents.len);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", agents[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.manual, agents[0].title_source);
    try std.testing.expectEqual(core.AgentTitleState.ready, agents[0].title_state);
    try std.testing.expect(second.model.workspaces.next_tab_id > core.raw(logs_tab));
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

    var tabs: [3]core.ClientTabLayout = undefined;
    var nodes: [3]core.ClientLayoutNode = undefined;
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
    try encoder.layout(.{ .identity = 42, .last_used = 1, .payload = try core.encodeClientLayoutUpdate(&layout_buffer, .{
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
    const reader = &runtime.model.workspaces;

    try std.testing.expect(!runtime.model.checkpoint.restore_failed);
    try std.testing.expectEqual(@as(u16, 3), runtime.model.checkpoint.restored_panes);
    try std.testing.expectEqual(@as(u16, 0), runtime.model.checkpoint.dropped_tabs);
    try std.testing.expectEqual(@as(usize, 2), reader.count);
    for ([_]u64{ 4, 2, 3 }, 0..) |pane_id, index| {
        const pane = runtime.model.panes.find(@enumFromInt(pane_id)).?;
        try std.testing.expectEqual(@as(u64, index + 1), core.raw(pane.location.tab_id));
        try std.testing.expect(pane.generation >= 9);
        try std.testing.expect(reader.contains(pane.location));
    }

    const exported = (try runtime.model.client_layouts.exportRecord(0, &layout_buffer)).?;
    const restored_layout = (try core.decodeClient(exported.payload)).update_client_layout;
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
            .agent_provider = @intFromEnum(core.AgentProvider.claude),
            .agent_session = reference,
            .agent_title = "Preserve pending resume",
            .agent_title_source = @intFromEnum(core.AgentTitleSource.manual),
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
        try std.testing.expectEqual(@as(u16, 2), runtime.model.checkpoint.restored_panes);
        try std.testing.expectEqual(@as(u16, 1), runtime.model.checkpoint.resumed_agents);
        const pane = runtime.model.panes.find(@enumFromInt(1)).?;
        try std.testing.expectEqualStrings("claude --resume " ++ reference ++ "\r", pane.input_queue.nextChunk().?);
        try std.testing.expectEqualStrings(reference, runtime.model.agents.resumeSession(pane.key()).?.reference.slice());
        try std.testing.expectEqualStrings("Preserve pending resume", runtime.model.agents.checkpointTitle(pane.key()).?.slice());
        try std.testing.expect(runtime.model.panes.find(@enumFromInt(2)).?.input_queue.nextChunk() == null);
        var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
        try std.testing.expectEqual(@as(usize, 0), runtime.model.agents.snapshot(&entries, 0).len);
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
        .agent_provider = @intFromEnum(core.AgentProvider.claude),
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
        const pane = runtime.model.panes.find(@enumFromInt(1)).?;
        try std.testing.expectEqualStrings(arguments, pane.launch_record.slice());
        try std.testing.expect(pane.input_queue.nextChunk() == null);
        try std.testing.expectEqual(@as(u16, if (resume_agents) 1 else 0), runtime.model.checkpoint.resumed_agents);
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
    const workspaces = &runtime.model.workspaces;
    const gpa = runtime.model.gpa;
    const workspace = try workspaces.insert(gpa, directory, null);
    var argument_buffer: [64]u8 = undefined;
    const pane = try pane_launch.launch(&runtime.model, .{
        .location = workspace,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunchIn(&argument_buffer, directory),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    try std.testing.expect(runtime.model.agents.observeSessionReference(agent_identity.fromPane(pane), try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100)));
    try std.testing.expect(runtime.model.agents.resumeSession(pane.key()) == null);

    for ([_]bool{ true, false }) |agent_foreground| {
        session_checkpoint.writeNow(&runtime.model);
        try std.testing.expect(!runtime.model.checkpoint.dirty);
        pane.queueHistoryOutput(.{ .bytes = "observed", .shell_foreground = false, .clock = pane_namespace.historyClock(io) });
        try std.testing.expect(pane.beginHistoryObservation() != null);
        const shell_id: u32 = @intCast(pane.session.processId());
        _ = try runtime.update(.{ .pane_observed = .{
            .pane = pane.key(),
            .stats = .{},
            .process_probe = .{
                .cache = .{ .process_group_id = if (agent_foreground) shell_id + 1 else shell_id, .provider = if (agent_foreground) .claude else .unknown },
                .changed = true,
                .inspected = true,
            },
        } });
        try std.testing.expect(runtime.model.checkpoint.dirty);
        try std.testing.expectEqual(agent_foreground, runtime.model.agents.resumeSession(pane.key()) != null);
    }
}
