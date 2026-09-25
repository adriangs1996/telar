//! A pane closes when a client asks or its child exits. The authoritative
//! exit revokes the pane's proxy credential; collection destroys the pane
//! once no actor or attachment borrows it and removes a tab left empty.
const agent_status = @import("agent_status.zig");

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const ExitCompletion = @import("events/ExitCompletion.zig");
const pty = @import("pty");
const exit_module = pty.exit;
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_observation = @import("pane_observation.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const tab_removal = @import("tab_removal.zig");

/// Requests PTY shutdown exactly once and marks review owners for
/// rediscovery. Pane retirement stays with the later exit event.
///
/// ```zig
/// const started = pane_closure.requestClose(model, pane);
/// ```
pub fn requestClose(model: *RuntimeModel, pane: *Pane) bool {
    if (!pane.requestClose()) {
        return false;
    }

    model.review_owner_revision +%= 1;
    return true;
}

/// Requests closure of an attached pane. The pane stays until its exit.
///
/// ```zig
/// try pane_closure.close(model, session, request);
/// ```
pub fn close(model: *RuntimeModel, session: *Session, request: core.ClosePane) !void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not attached");
    };

    _ = requestClose(model, attachment.pane);
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
    revokeCredential(model, transition.pane);

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
        _ = store.removeExitedAt(index);
        _ = agent_status.remove(model, pane.key());

        revokeCredential(model, pane);
        pane.destroy();
        session_checkpoint.noteChange(model);

        if (!store.hasAt(location) and model.workspaces.contains(location)) {
            const removed = model.workspaces.removeTab(model.gpa, location).?;
            tab_removal.announce(model, removed);
        }

        leaveEmptyWorkspace(model, location.workspace);
    }
}

/// Revokes the pane generation's proxy credential, when the proxy runs.
/// Example: `pane_closure.revokeCredential(model, pane);`.
pub fn revokeCredential(model: *RuntimeModel, pane: *Pane) void {
    if (model.resources.proxy.capability()) |proxy| {
        proxy.revokePane(pane.key());
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
