//! A pane closes when a client asks or its child exits. Collection destroys
//! the pane once no actor or attachment borrows it and removes a tab left
//! empty.
const agent_status = @import("agent_status.zig");

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const ExitedPanes = @import("../pane/ExitedPanes.zig");
const ExitCompletion = @import("events/ExitCompletion.zig");
const pty = @import("pty");
const exit_module = pty.exit;
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_observation = @import("pane_observation.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const tab_removal = @import("tab_removal.zig");
const worktree_lifecycle = @import("worktree_lifecycle.zig");
const PaneFixture = @import("tests/PaneFixture.zig");

/// Requests closure of an attached pane. The pane stays until its exit.
///
/// ```zig
/// try pane_closure.close(model, session, request);
/// ```
pub fn close(model: *RuntimeModel, session: *Session, request: core.ClosePane) !void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not attached");
    };

    _ = attachment.pane.requestClose();
}

/// Commits the child's exit, retires its agent and credential, and
/// schedules the final history observation once output has drained.
///
/// ```zig
/// try pane_closure.finishExit(model, completion);
/// ```
pub fn finishExit(model: *RuntimeModel, completion: ExitCompletion) !void {
    const transition = model.panes.completeExit(completion.pane, exitOrSynthetic(completion.result)) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    _ = agent_status.remove(model, transition.pane.key());
    worktree_lifecycle.finishCommand(model, transition.pane.id, transition.exit.code());

    if (transition.launch_aborting) {
        return;
    }

    if (transition.output_done) {
        transition.pane.queueExitedHistory(transition.exit);
        try pane_observation.start(model, transition.pane);
    }
}

/// Destroys exited panes that no actor or attachment borrows, removes tabs
/// left without panes and completes deferred workspace departures. Costs
/// one branch while nothing has exited.
///
/// ```zig
/// pane_closure.collect(model);
/// ```
pub fn collect(model: *RuntimeModel) void {
    const store = &model.panes;
    if (store.exited_count == 0) {
        return;
    }

    for (store.items, 0..) |entry, index| {
        const pane = entry orelse continue;

        if (!pane.readyToDestroy() or pane.observers != 0) {
            continue;
        }

        const location = pane.location;
        keepExitText(store, pane);
        _ = store.removeExitedAt(index);
        _ = agent_status.remove(model, pane.key());

        pane.destroy();
        session_checkpoint.noteChange(model);

        if (!store.hasAt(location) and model.workspaces.contains(location)) {
            const removed = model.workspaces.removeTab(model.gpa, location).?;
            tab_removal.announce(model, removed);
            if (removed.workspace_removed) {
                worktree_lifecycle.releaseWorkspace(model, removed.location.workspace);
            }
        }

        leaveEmptyWorkspace(model, location.workspace);
    }
}

/// Completes departures deferred by a pane exit only after every pane that
/// can still publish lifecycle changes for the workspace is reaped.
fn leaveEmptyWorkspace(model: *RuntimeModel, workspace: core.WorkspaceLocation) void {
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;

        if (pane.exit != null and std.meta.eql(pane.location.workspace, workspace)) {
            return;
        }
    }

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (pane_attachment.leaveWorkspace(model, session, workspace)) {
            geometry_lease.release(model, session.key, workspace);
        }
    }
}

/// Keeps a collected pane's newest rows and exit status, so its output,
/// down to a test summary or the final error, stays readable after the pane
/// is gone. The record is truncated when rows beyond `kept_rows` or bytes
/// beyond the buffer were dropped.
fn keepExitText(store: *PaneStore, pane: *const Pane) void {
    const exit = pane.exit orelse return;
    var storage: [ExitedPanes.max_text_bytes]u8 = undefined;
    const dump = pane.dumpText(.{ .rows = ExitedPanes.kept_rows, .source = .recent }, &storage);
    store.exited.record(pane.key(), exit.code(), .{
        .text = storage[0..dump.len],
        .truncated = dump.truncated or pane.textRows(.recent) > ExitedPanes.kept_rows,
    });
}

fn exitOrSynthetic(result: anyerror!exit_module.Exit) exit_module.Exit {
    return result catch .{ .signaled = .KILL };
}

test "wait failure becomes a synthetic SIGKILL exit" {
    try std.testing.expectEqual(
        exit_module.Exit{ .signaled = .KILL },
        exitOrSynthetic(error.WaitpidFailed),
    );
    try std.testing.expectEqual(
        exit_module.Exit{ .exited = 7 },
        exitOrSynthetic(exit_module.Exit{ .exited = 7 }),
    );
}

test "an exited pane's record is truncated when it printed more rows than it keeps" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var line_buffer: [16]u8 = undefined;
    for (1..2001) |number| {
        _ = try fixture.pane.ingest(std.testing.io, try std.fmt.bufPrint(&line_buffer, "l{d}\r\n", .{number}));
    }

    const store = try std.testing.allocator.create(PaneStore);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    fixture.pane.exit = .{ .exited = 0 };
    defer fixture.pane.exit = null;

    keepExitText(store, fixture.pane);
    const slot = store.exited.find(fixture.pane.key()).?;

    try std.testing.expectEqualStrings("l2000", store.exited.tail(slot, 1).text);
    try std.testing.expect(!store.exited.tail(slot, 1).truncated);
    try std.testing.expect(store.exited.tail(slot, ExitedPanes.kept_rows).truncated);
}
