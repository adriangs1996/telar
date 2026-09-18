const std = @import("std");
const Runtime = @import("../Runtime.zig");
const Initialization = @import("../Initialization.zig");
const Encoder = @import("telar-core").Encoder;
const LaunchView = @import("telar-core").LaunchView;
const commands = @import("../../workspace/commands.zig");
const PersistenceEncoder = @import("../../persistence/Encoder.zig");

test "shutdown replaces a pending checkpoint with the latest session and releases its buffer" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/shutdown.sock", .{directory});
    var checkpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrint(&checkpoint_buffer, "{s}/session.ckpt", .{directory});
    const initialization: Initialization = .{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = checkpoint_path },
    };

    var first: Runtime = undefined;
    try first.init(initialization);
    defer first.deinit();

    var repository = first.application.workspaceRepository();
    const workspace = try repository.ensure(directory);
    var launch_buffer: [64]u8 = undefined;
    const launch = try sleepLaunch(&launch_buffer);
    const first_pane = try first.application.launchPane(.{
        .location = workspace.location,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = launch,
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const first_pane_id = first_pane.id;

    first.application.session.last_change_ns = 0;
    try first.application.flushSessionCheckpoint();
    try std.testing.expect(first.application.session.pending != null);

    const tab_id = try repository.nextTabId();
    _ = try repository.find(workspace.location.workspace).?.createTab(tab_id, "late tab");
    repository.recordTabCreated(tab_id);
    const second_pane = try first.application.launchPane(.{
        .location = .{ .workspace = workspace.location.workspace, .tab_id = tab_id },
        .size = .{ .cols = 20, .rows = 5 },
        .launch = launch,
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const second_pane_id = second_pane.id;
    _ = try commands.renameWorkspace(&repository, workspace.location.workspace, "latest name");

    first.deinit();
    try std.testing.expect(first.application.session.pending == null);
    try std.testing.expectEqual(@as(u64, 1), first.application.session.writes);
    try std.testing.expectEqual(@as(u64, 0), first.application.session.failures);

    var second: Runtime = undefined;
    try second.init(initialization);
    defer second.deinit();

    try std.testing.expect(!second.application.session.restore_failed);
    try std.testing.expectEqual(@as(u16, 2), second.application.session.restored_panes);
    try std.testing.expect(second.application.model.panes.find(first_pane_id) != null);
    try std.testing.expect(second.application.model.panes.find(second_pane_id) != null);
    const reader = second.application.workspaceReader();
    try std.testing.expectEqualStrings("latest name", reader.workspaceName(workspace.location.workspace).?);
    try std.testing.expectEqualStrings("late tab", reader.tabLabel(.{ .workspace = workspace.location.workspace, .tab_id = tab_id }).?);
}

fn sleepLaunch(buffer: []u8) !LaunchView {
    var encoder = Encoder.init(buffer);
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

test "failed startup joins restored children and preserves the original checkpoint" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/failed-start.sock", .{directory});
    var checkpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrint(&checkpoint_buffer, "{s}/session.ckpt", .{directory});
    var bytes: [1024]u8 = undefined;
    var encoder = try PersistenceEncoder.init(&bytes, .{
        .next_workspace_id = 2,
        .next_tab_id = 2,
        .next_pane_id = 2,
        .next_pane_generation = 2,
    });
    try encoder.workspace(.{ .id = 1, .path = directory, .name = "saved workspace", .first_tab_id = 1, .first_tab_label = "saved tab" });
    try encoder.pane(.{
        .pane_id = 1,
        .workspace_id = 1,
        .tab_id = 1,
        .cwd = directory,
        .cols = 20,
        .rows = 5,
        .arguments = "/bin/sleep\x00600\x00",
        .argument_count = 2,
    });
    const saved = try encoder.finish();
    try temp.dir.writeFile(io, .{ .sub_path = "session.ckpt", .data = saved });

    var runtime: Runtime = undefined;
    try std.testing.expectError(error.InjectedStartupFailure, runtime.start(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ, .session_path = checkpoint_path },
    }, true));
    try std.testing.expectEqual(@as(u16, 1), runtime.application.session.restored_panes);
    try std.testing.expectEqual(@as(usize, 0), runtime.application.model.panes.count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }));

    const kept = try temp.dir.readFileAlloc(io, "session.ckpt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualSlices(u8, saved, kept);
}

const managed_provider =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\ case "$line" in
    \\ *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    \\ *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake model","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
    \\ *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"saved-thread"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
    \\ *'"method":"thread/resume"'*) printf '{"id":2,"result":{"thread":{"id":"saved-thread","cwd":"%s","status":{"type":"idle"}},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}\n' "$PWD" ;;
    \\ esac
    \\done
;

fn awaitManagedPane(runtime: *Runtime, pane: *@import("../../pane/Pane.zig")) !void {
    while (true) {
        switch (try runtime.loop.next()) {
            .agent_thread_changed => |changed| {
                if (try @import("../application/agent_threads.zig").handle(&runtime.application, changed)) {
                    return error.ProviderStopped;
                }

                if (pane.agent_thread.?.status == .failed) {
                    return error.ProviderFailed;
                }

                if (pane.agent_thread.?.status == .ready) {
                    return;
                }
            },
            else => {},
        }
    }
}

test "agent panes survive consecutive runtime checkpoints with their kind identity conversation and title" {
    const core = @import("telar-core");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    const script = try temp.dir.createFile(io, "codex", .{ .permissions = .fromMode(0o700) });
    try script.writeStreamingAll(io, managed_provider);
    script.close(io);
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("PATH", directory);
    try environment.put("HOME", directory);
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(gpa, .{}) };
    defer inherited.block.deinit(gpa);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/managed.sock", .{directory});
    var checkpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrint(&checkpoint_buffer, "{s}/session.ckpt", .{directory});
    var initialization: Initialization = .{
        .dependencies = .{ .io = io, .allocator = gpa },
        .options = .{ .endpoint = endpoint, .environment = inherited, .session_path = checkpoint_path },
    };
    const first = try gpa.create(Runtime);
    defer gpa.destroy(first);
    try first.init(initialization);
    defer first.deinit();
    var repository = first.application.workspaceRepository();
    const workspace = try repository.ensure(directory);
    var launch_buffer: [64]u8 = undefined;
    const terminal = try first.application.launchPane(.{
        .location = workspace.location,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = try sleepLaunch(&launch_buffer),
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const terminal_id = terminal.id;
    const tab_id = try repository.nextTabId();
    _ = try repository.find(workspace.location.workspace).?.createTab(tab_id, "Agent work");
    repository.recordTabCreated(tab_id);
    const location: core.TabLocation = .{ .workspace = workspace.location.workspace, .tab_id = tab_id };
    const pane = try first.application.launchPane(.{
        .location = location,
        .kind = .agent,
        .size = .{ .cols = 100, .rows = 30 },
        .launch = .{ .cwd = directory, .argument_count = 0, .encoded_arguments = "", .environment_mode = .inherit_runtime, .environment_count = 0, .encoded_environment = "" },
        .launch_cwd = directory,
        .workspace_path = directory,
    });
    const pane_id = pane.id;
    const first_generation = pane.generation;
    first.application.session.dirty = false;
    try awaitManagedPane(first, pane);
    try std.testing.expect(first.application.session.dirty);
    try std.testing.expect(!pane.agent_thread.?.resumed);
    // A contended publication must defer persistence without failing maintenance.
    pane.session.agent.session.mutex.lockUncancelable(io);
    {
        defer pane.session.agent.session.mutex.unlock(io);
        first.application.session.last_change_ns = 0;
        try first.application.flushSessionCheckpoint();
        try std.testing.expect(first.application.session.pending == null);
        try std.testing.expect(first.application.session.dirty);
    }

    first.application.restoreAgentTitle(pane, try @import("../../agent/SessionTitle.zig").init("Keep this title", .manual));
    first.deinit();

    // A second shutdown before processing provider events must preserve the intention.
    const second = try gpa.create(Runtime);
    defer gpa.destroy(second);
    try second.init(initialization);
    defer second.deinit();
    try std.testing.expectEqual(@as(u16, 2), second.application.session.restored_panes);
    const starting = second.application.model.panes.find(pane_id).?;
    try std.testing.expectEqual(core.PaneKind.agent, starting.kind);
    try std.testing.expect(starting.generation > first_generation);
    try std.testing.expectEqualStrings("saved-thread", starting.agent_thread.?.threadId());
    second.deinit();

    const third = try gpa.create(Runtime);
    defer gpa.destroy(third);
    try third.init(initialization);
    defer third.deinit();
    const restored = third.application.model.panes.find(pane_id).?;
    try awaitManagedPane(third, restored);
    try std.testing.expect(restored.agent_thread.?.resumed);
    try std.testing.expect(restored.agent_thread.?.truncated);
    try std.testing.expectEqualStrings("saved-thread", restored.agent_thread.?.threadId());
    try std.testing.expectEqualStrings(directory, restored.cwd.slice());
    try std.testing.expectEqual(location, restored.location);
    try std.testing.expectEqual(@as(u16, 100), restored.size.cols);
    try std.testing.expectEqual(@as(u16, 30), restored.size.rows);
    try std.testing.expectEqualStrings("Agent work", third.application.workspaceReader().tabLabel(location).?);
    try std.testing.expectEqualStrings("Keep this title", third.application.model.agents.checkpointTitle(restored.key()).?.slice());
    try std.testing.expectEqual(core.PaneKind.terminal, third.application.model.panes.find(terminal_id).?.kind);
    try std.testing.expectEqual(@as(u16, 1), third.application.session.resumed_agents);
    third.deinit();

    initialization.options.resume_agents = false;
    const fresh = try gpa.create(Runtime);
    defer gpa.destroy(fresh);
    try fresh.init(initialization);
    defer fresh.deinit();
    const fresh_pane = fresh.application.model.panes.find(pane_id).?;
    try awaitManagedPane(fresh, fresh_pane);
    try std.testing.expectEqual(core.PaneKind.agent, fresh_pane.kind);
    try std.testing.expect(!fresh_pane.agent_thread.?.resumed);
    try std.testing.expectEqual(@as(u16, 0), fresh.application.session.resumed_agents);
    try std.testing.expect(fresh.application.model.agents.checkpointTitle(fresh_pane.key()) == null);
}

test "agent checkpoint skips duplicate claims and retains empty panes when the provider is unavailable" {
    const core = @import("telar-core");
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/duplicate.sock", .{directory});
    var checkpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrint(&checkpoint_buffer, "{s}/session.ckpt", .{directory});
    var bytes: [2048]u8 = undefined;
    var encoder = try PersistenceEncoder.init(&bytes, .{ .next_workspace_id = 2, .next_tab_id = 2, .next_pane_id = 4, .next_pane_generation = 4 });
    try encoder.workspace(.{ .id = 1, .path = directory, .name = "", .first_tab_id = 1, .first_tab_label = "" });
    for ([_][]const u8{ "saved-thread", "saved-thread", "" }, 1..) |reference, id| {
        try encoder.pane(.{
            .kind = .agent,
            .pane_id = id,
            .workspace_id = 1,
            .tab_id = 1,
            .cwd = directory,
            .cols = 80,
            .rows = 24,
            .arguments = "",
            .argument_count = 0,
            .agent_provider = @intFromEnum(core.AgentProvider.codex),
            .agent_session = reference,
        });
    }

    try temp.dir.writeFile(io, .{ .sub_path = "session.ckpt", .data = try encoder.finish() });
    // The isolated directory has no provider executable.
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", directory);
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(std.testing.allocator, .{}) };
    defer inherited.block.deinit(std.testing.allocator);
    const initialization: Initialization = .{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = inherited, .session_path = checkpoint_path },
    };
    for (0..2) |_| {
        var runtime: Runtime = undefined;
        try runtime.init(initialization);
        defer runtime.deinit();
        try std.testing.expect(!runtime.application.session.restore_failed);
        try std.testing.expectEqual(@as(u16, 2), runtime.application.session.restored_panes);
        try std.testing.expectEqual(@as(u16, 1), runtime.application.session.resumed_agents);
        try std.testing.expectEqualStrings("saved-thread", runtime.application.model.panes.find(@enumFromInt(1)).?.agent_thread.?.threadId());
        try std.testing.expect(runtime.application.model.panes.find(@enumFromInt(2)) == null);
        try std.testing.expectEqual(core.PaneKind.agent, runtime.application.model.panes.find(@enumFromInt(3)).?.kind);
    }
}
