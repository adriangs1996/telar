//! A workspace mutation asks every other client observing that workspace
//! for a snapshot resync; the next flush delivers it.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const ClientKey = @import("../history/ClientKey.zig");

const WorkspaceChange = struct {
    origin: ClientKey,
    workspace: core.WorkspaceLocation,
    previous_workspace: ?core.WorkspaceId = null,
};

/// Flags a resync for every active observer except the mutation origin.
///
/// ```zig
/// resync_required.notify(model, .{ .origin = session.key, .workspace = workspace });
/// ```
pub fn notify(model: *RuntimeModel, change: WorkspaceChange) void {
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (std.meta.eql(session.key, change.origin) or !session.active()) {
            continue;
        }

        if (session.attachments.observes(change.workspace)) {
            session.delivery.requestWorkspaceResync(change.workspace, change.previous_workspace);
        }
    }
}
