//! A worktree is registered by the CLI after it added the checkout, receives
//! launches that create its workspace and then add tabs to it, records the
//! commands it runs, and is forgotten with every tab it holds. See
//! `docs/flows/worktree-lifecycle.md`.

const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const Worktrees = @import("../workspace/Worktrees.zig");
const client_request = @import("client_request.zig");
const pane_launch = @import("pane_launch.zig");
const resync_required = @import("resync_required.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const tab_removal = @import("tab_removal.zig");

/// Tracks the worktree a CLI created and answers with its identity.
///
/// ```zig
/// try worktree_lifecycle.register(model, session, request);
/// ```
pub fn register(model: *RuntimeModel, session: *Session, request: core.RegisterWorktree) !void {
    if (!model.workspaces.containsWorkspace(.{ .workspace = request.source })) {
        return client_request.fail(session, request.request_id, .workspace_not_found, "source workspace not found");
    }

    const registered = model.worktrees.register(model.gpa, .{
        .source = request.source,
        .created_by = request.created_by,
        .origin = request.origin,
        .path = request.path,
        .branch = request.branch,
        .base = request.base,
        .title = request.title,
        .brief = request.brief,
        .dispatched_from = request.dispatched_from,
    }) catch |err| return switch (err) {
        error.WorktreeLimitReached => client_request.fail(session, request.request_id, .resource_limit, "worktree limit reached"),
        error.OutOfMemory => err,
        else => client_request.fail(session, request.request_id, .invalid_request, "invalid worktree"),
    };

    announce(model);
    try session.delivery.responses.push(.{ .worktree_registered = .{
        .request_id = request.request_id,
        .worktree = registered.id,
        .created = registered.created,
    } });
}

/// Starts a command in a worktree without attaching or leasing anything for
/// the sender, so a coordinator can drive a worktree a person is watching.
/// The first launch creates the worktree's workspace; later ones add tabs.
///
/// ```zig
/// try worktree_lifecycle.launch(model, session, request);
/// ```
pub fn launch(model: *RuntimeModel, session: *Session, request: core.LaunchWorktreeView) !void {
    const opened = launchCommand(model, session, request) catch |err| {
        return switch (err) {
            error.WorktreeNotFound => client_request.fail(session, request.request_id, .worktree_not_found, "worktree not found"),
            error.WorkspaceCreateFailed => client_request.fail(session, request.request_id, .resource_limit, "could not create the worktree workspace"),
            error.TabLimitReached => client_request.fail(session, request.request_id, .resource_limit, "tab limit reached"),
            error.InvalidTabLabel => client_request.fail(session, request.request_id, .invalid_request, "invalid tab label"),
            error.PaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, "pane limit reached"),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            error.PaneSpawnFailed => client_request.fail(session, request.request_id, .spawn_failed, "could not start the command"),
            else => err,
        };
    };

    try session.delivery.responses.push(.{ .pane_opened = opened });
}

/// Closes every tab of the worktree's workspace and stops tracking it. The
/// checkout stays on disk; removing it is the CLI's decision.
///
/// ```zig
/// try worktree_lifecycle.forget(model, session, request);
/// ```
pub fn forget(model: *RuntimeModel, session: *Session, request: core.ForgetWorktree) !void {
    const slot = model.worktrees.slotOf(request.worktree) orelse {
        return client_request.fail(session, request.request_id, .worktree_not_found, "worktree not found");
    };

    if (model.worktrees.workspace[slot]) |workspace_id| {
        closeWorkspace(model, workspace_id);
    }

    _ = model.worktrees.remove(model.gpa, request.worktree);
    announce(model);
    try client_request.complete(session, request.request_id);
}

/// Forgets the workspace link of a worktree whose workspace lost its last
/// tab, so the next launch creates a fresh one.
///
/// ```zig
/// if (removed.workspace_removed) worktree_lifecycle.releaseWorkspace(model, removed.location.workspace);
/// ```
pub fn releaseWorkspace(model: *RuntimeModel, workspace: core.WorkspaceLocation) void {
    const workspace_id = switch (workspace) {
        .workspace => |id| id,
        .worktree => return,
    };

    if (model.worktrees.releaseWorkspace(workspace_id)) {
        announce(model);
    }
}

/// Records the exit of the last command launched in a worktree.
///
/// ```zig
/// worktree_lifecycle.finishCommand(model, pane.id, exit.code());
/// ```
pub fn finishCommand(model: *RuntimeModel, pane_id: core.PaneId, exit_code: i32) void {
    if (model.worktrees.finishCommand(pane_id, exit_code)) {
        model.workspaces.advanceRevision();
    }
}

/// Publishes a worktree change through the workspace list and schedules a
/// checkpoint.
///
/// ```zig
/// worktree_lifecycle.announce(model);
/// ```
pub fn announce(model: *RuntimeModel) void {
    model.workspaces.advanceRevision();
    session_checkpoint.noteChange(model);
}

fn launchCommand(model: *RuntimeModel, session: *Session, request: core.LaunchWorktreeView) !core.PaneOpened {
    const slot = model.worktrees.slotOf(request.worktree) orelse return error.WorktreeNotFound;
    if (model.worktrees.workspace[slot]) |workspace_id| {
        if (model.workspaces.slotOf(.{ .workspace = workspace_id })) |workspace_slot| {
            return addTab(model, session, .{
                .worktree_slot = slot,
                .workspace_slot = workspace_slot,
                .request = request,
            });
        }

        model.worktrees.workspace[slot] = null;
    }

    return createWorkspace(model, slot, request);
}

fn createWorkspace(model: *RuntimeModel, slot: usize, request: core.LaunchWorktreeView) !core.PaneOpened {
    const worktrees = &model.worktrees;
    const path = worktrees.path[slot];
    const proposal = model.workspaces.propose(model.gpa, path, workspaceName(worktrees, slot)) catch return error.WorkspaceCreateFailed;
    defer model.workspaces.rollback(model.gpa, proposal);

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = model.workspaces.id[proposal] },
        .tab_id = model.workspaces.tab_id[proposal][0],
    };
    const pane = pane_launch.launch(model, .{
        .location = location,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = path,
        .workspace_path = model.workspaces.path[proposal],
    }) catch |err| return pane_launch.requestError(err);

    _ = model.workspaces.commit(proposal);
    if (request.label.len != 0) {
        try model.workspaces.renameTab(location, request.label);
    }

    worktrees.workspace[slot] = model.workspaces.id[proposal];
    startCommand(model, slot, pane, request);
    return .{
        .request_id = request.request_id,
        .pane_id = pane.id,
        .location = location,
        .created = true,
        .pane_generation = pane.generation,
    };
}

const TabLaunch = struct {
    worktree_slot: usize,
    workspace_slot: usize,
    request: core.LaunchWorktreeView,
};

fn addTab(model: *RuntimeModel, session: *Session, tab: TabLaunch) !core.PaneOpened {
    const workspaces = &model.workspaces;
    const workspace_id = workspaces.id[tab.workspace_slot];
    const tab_id = try workspaces.nextTabId();
    const position = try workspaces.addTab(tab.workspace_slot, tab_id, tab.request.label);
    const location: core.TabLocation = .{ .workspace = .{ .workspace = workspace_id }, .tab_id = tab_id };
    var committed = false;
    defer if (!committed) {
        std.debug.assert(workspaces.tab_count[tab.workspace_slot] == position + 1);
        workspaces.tab_count[tab.workspace_slot] -= 1;
    };

    const pane = pane_launch.launch(model, .{
        .location = location,
        .size = tab.request.size,
        .launch = tab.request.launch,
        .launch_cwd = model.worktrees.path[tab.worktree_slot],
        .workspace_path = workspaces.path[tab.workspace_slot],
    }) catch |err| return pane_launch.requestError(err);

    workspaces.recordTabCreated(tab_id);
    committed = true;
    resync_required.notify(model, .{ .origin = session.key, .workspace = location.workspace });
    startCommand(model, tab.worktree_slot, pane, tab.request);
    return .{
        .request_id = tab.request.request_id,
        .pane_id = pane.id,
        .location = location,
        .created = false,
        .pane_generation = pane.generation,
    };
}

fn startCommand(model: *RuntimeModel, slot: usize, pane: *Pane, request: core.LaunchWorktreeView) void {
    var arguments = request.launch.arguments();
    const program = (arguments.next() catch null) orelse "";
    model.worktrees.startCommand(slot, pane.id, commandLabel(program));
    announce(model);
}

/// The program's base name, cut to the label bound on a UTF-8 boundary.
fn commandLabel(program: []const u8) []const u8 {
    const name = std.fs.path.basename(program);
    var len = @min(name.len, core.max_worktree_command_label_bytes);
    while (len > 0 and len < name.len and (name[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    return name[0..len];
}

fn workspaceName(worktrees: *const Worktrees, slot: usize) []const u8 {
    const name = worktrees.displayName(slot);
    return name[0..@min(name.len, core.max_tab_label_bytes)];
}

fn closeWorkspace(model: *RuntimeModel, workspace_id: core.WorkspaceId) void {
    const location: core.WorkspaceLocation = .{ .workspace = workspace_id };
    while (model.workspaces.defaultTab(location)) |tab_id| {
        const removed = model.workspaces.removeTab(model.gpa, .{ .workspace = location, .tab_id = tab_id }) orelse break;
        model.panes.closeAt(removed.location);
        tab_removal.announce(model, removed);
    }

    model.review_owner_revision +%= 1;
    session_checkpoint.noteChange(model);
}

test "command labels keep the program name within the wire bound" {
    try std.testing.expectEqualStrings("claude", commandLabel("/usr/local/bin/claude"));
    try std.testing.expectEqualStrings("zig", commandLabel("zig"));
    try std.testing.expectEqual(@as(usize, core.max_worktree_command_label_bytes), commandLabel("/x/" ++ "a" ** 80).len);
}
