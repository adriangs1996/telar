//! The worktree lifecycle through the runtime's dispatch: registration,
//! launches into the worktree's own workspace and forgetting it.

const std = @import("std");
const core = @import("telar-core");
const bytecodec = @import("bytecodec");
const pty = @import("pty");
const RequestFixture = @import("RequestFixture.zig");
const pane_launch = @import("../pane_launch.zig");

const request: core.RequestId = @enumFromInt(41);

/// A registered worktree whose checkout is the fixture's temporary directory.
const Registered = struct {
    source: core.WorkspaceId,
    worktree: core.WorktreeId,
};

fn register(fixture: *RequestFixture, path: []const u8) !Registered {
    const model = &fixture.runtime.model;
    const source = try model.workspaces.insert(model.gpa, "/", null);
    try fixture.send(.{ .register_worktree = .{
        .request_id = request,
        .source = source.workspace.workspace,
        .path = path,
        .branch = "fix-tabs",
        .base = "main",
        .title = "Fix tabs",
    } });
    const response = fixture.response() orelse return error.MissingReply;
    try std.testing.expect(response.* == .worktree_registered);
    try std.testing.expect(response.worktree_registered.created);
    const worktree = response.worktree_registered.worktree;
    fixture.clearResponses();
    return .{
        .source = source.workspace.workspace,
        .worktree = worktree,
    };
}

fn launch(fixture: *RequestFixture, worktree: core.WorktreeId, label: []const u8) !core.PaneOpened {
    var launch_buffer: [64]u8 = undefined;
    try fixture.send(.{ .launch_worktree = .{
        .request_id = request,
        .worktree = worktree,
        .label = label,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try RequestFixture.sleepLaunch(&launch_buffer),
    } });
    const response = fixture.response() orelse return error.MissingReply;
    if (response.* != .pane_opened) {
        return error.LaunchFailed;
    }

    const opened = response.pane_opened;
    fixture.clearResponses();
    return opened;
}

fn temporaryPath(fixture: *RequestFixture, buffer: []u8) ![]const u8 {
    return buffer[0..try fixture.temporary.dir.realPath(std.testing.io, buffer)];
}

test "a worktree registers once, then launches build its workspace and add tabs to it" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&fixture, &path_buffer);
    const registered = try register(&fixture, path);

    try fixture.send(.{ .register_worktree = .{
        .request_id = request,
        .source = registered.source,
        .path = path,
        .branch = "fix-tabs",
        .title = "Order tabs by use",
    } });
    const again = fixture.response().?;
    try std.testing.expect(!again.worktree_registered.created);
    try std.testing.expectEqual(registered.worktree, again.worktree_registered.worktree);
    fixture.clearResponses();

    const slot = model.worktrees.slotOf(registered.worktree).?;
    try std.testing.expectEqualStrings("Order tabs by use", model.worktrees.titleAt(slot));
    try std.testing.expectEqualStrings("main", model.worktrees.baseAt(slot));
    try std.testing.expect(model.worktrees.workspace[slot] == null);

    const first = try launch(&fixture, registered.worktree, "agent");
    try std.testing.expect(first.created);
    const child = model.worktrees.workspace[slot].?;
    try std.testing.expectEqual(core.WorkspaceLocation{ .workspace = child }, first.location.workspace);
    try std.testing.expect(child != registered.source);
    try std.testing.expectEqual(core.CommandState.running, model.worktrees.command_state[slot]);
    try std.testing.expectEqualStrings("sleep", model.worktrees.commandLabelAt(slot));

    const second = try launch(&fixture, registered.worktree, "tests");
    try std.testing.expect(!second.created);
    try std.testing.expectEqual(first.location.workspace, second.location.workspace);
    try std.testing.expect(first.location.tab_id != second.location.tab_id);
    try std.testing.expectEqual(first.location.workspace, model.panes.find(second.pane_id).?.location.workspace);
}

test "a command run through the login shell is named after the command" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const registered = try register(&fixture, try temporaryPath(&fixture, &path_buffer));

    var storage: [pty.login_shell.wrapper_len + 2][]const u8 = undefined;
    const argv = try pty.login_shell.wrap("/bin/sh", &.{ "/bin/sleep", "600" }, &storage);
    var argument_buffer: [128]u8 = undefined;
    var encoder = bytecodec.Encoder.init(&argument_buffer);
    for (argv) |argument| {
        try encoder.writeSized16(argument);
    }

    try fixture.send(.{ .launch_worktree = .{
        .request_id = request,
        .worktree = registered.worktree,
        .label = "",
        .size = .{ .cols = 20, .rows = 5 },
        .launch = .{
            .cwd = "/",
            .argument_count = @intCast(argv.len),
            .encoded_arguments = encoder.finish(),
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
    } });
    try std.testing.expect(fixture.response().?.* == .pane_opened);

    const slot = model.worktrees.slotOf(registered.worktree).?;
    try std.testing.expectEqualStrings("sleep", model.worktrees.commandLabelAt(slot));
}

test "a launch into a worktree the runtime does not track fails without a workspace" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const workspaces_before = fixture.runtime.model.workspaces.count;

    try std.testing.expectError(error.LaunchFailed, launch(&fixture, @enumFromInt(7), ""));
    try std.testing.expectEqual(workspaces_before, fixture.runtime.model.workspaces.count);
}

test "a launch whose program the runtime cannot find says so" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const registered = try register(&fixture, try temporaryPath(&fixture, &path_buffer));

    var argument_buffer: [64]u8 = undefined;
    var encoder = bytecodec.Encoder.init(&argument_buffer);
    try encoder.writeSized16("telar-test-missing-program");
    try fixture.send(.{ .launch_worktree = .{
        .request_id = request,
        .worktree = registered.worktree,
        .label = "",
        .size = .{ .cols = 20, .rows = 5 },
        .launch = .{
            .cwd = "/",
            .argument_count = 1,
            .encoded_arguments = encoder.finish(),
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
    } });

    const response = fixture.response().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(core.FailureCode.spawn_failed, response.request_failed.code);
    try std.testing.expectEqualStrings(pane_launch.program_not_found, response.request_failed.message);
}

test "registration refuses a source workspace the runtime does not have" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.send(.{ .register_worktree = .{
        .request_id = request,
        .source = @enumFromInt(99),
        .path = "/w/fix",
        .branch = "fix",
    } });
    const response = fixture.response().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(core.FailureCode.workspace_not_found, response.request_failed.code);
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.model.worktrees.count);
}

test "forgetting a worktree closes its workspace and drops the row once" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const registered = try register(&fixture, try temporaryPath(&fixture, &path_buffer));
    const opened = try launch(&fixture, registered.worktree, "agent");

    try fixture.send(.{ .forget_worktree = .{
        .request_id = request,
        .worktree = registered.worktree,
    } });
    const response = fixture.response().?;
    try std.testing.expect(response.* == .request_completed);
    fixture.clearResponses();

    try std.testing.expect(model.worktrees.slotOf(registered.worktree) == null);
    try std.testing.expect(!model.workspaces.containsWorkspace(opened.location.workspace));
    try std.testing.expect(model.workspaces.containsWorkspace(.{ .workspace = registered.source }));
    try std.testing.expect(model.panes.find(opened.pane_id) == null or model.panes.find(opened.pane_id).?.close_requested);

    try fixture.send(.{ .forget_worktree = .{
        .request_id = request,
        .worktree = registered.worktree,
    } });
    const missing = fixture.response().?;
    try std.testing.expect(missing.* == .request_failed);
    try std.testing.expectEqual(core.FailureCode.worktree_not_found, missing.request_failed.code);
}
