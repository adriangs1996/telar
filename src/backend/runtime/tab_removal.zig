//! A tab disappears from its workspace, requested by a client or caused by
//! the loss of its final pane. A workspace left without tabs goes with it.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const TabRemoved = @import("../workspace/TabRemoved.zig");
const client_request = @import("client_request.zig");
const resync_required = @import("resync_required.zig");

/// Removes the tab, asks its panes to close and resyncs other observers.
///
/// ```zig
/// try tab_removal.remove(model, session, request);
/// ```
pub fn remove(model: *RuntimeModel, session: *Session, request: core.CloseTab) !void {
    const removed = model.workspaces.removeTab(model.gpa, request.location) orelse {
        return client_request.fail(session, request.request_id, .tab_not_found, "tab not found");
    };

    model.panes.closeAt(removed.location);
    session_checkpoint.noteChange(model);
    resync_required.notify(model, .{
        .origin = session.key,
        .workspace = removed.location.workspace,
        .previous_workspace = if (removed.workspace_removed) removed.previous_workspace else null,
    });

    try session.delivery.responses.push(.{ .tab_closed = .{
        .request_id = request.request_id,
        .location = removed.location,
        .workspace_closed = removed.workspace_removed,
        .previous_workspace = removed.previous_workspace,
    } });
}

/// Delivers a tab removal caused by pane exit to every client still
/// observing its workspace. Queue saturation records snapshot recovery.
///
/// ```zig
/// tab_removal.announce(model, removed);
/// ```
pub fn announce(model: *RuntimeModel, removed: TabRemoved) void {
    for (&model.clients.items) |*slot| {
        const client = slot.* orelse continue;

        if (!client.active() or !client.attachments.observes(removed.location.workspace)) {
            continue;
        }

        client.delivery.responses.pushOrDrop(.{ .tab_closed = .{
            .request_id = .none,
            .location = removed.location,
            .workspace_closed = removed.workspace_removed,
            .previous_workspace = removed.previous_workspace,
        } });
    }
}
