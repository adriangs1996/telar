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
