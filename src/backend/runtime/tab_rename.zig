//! A client renames a tab; other observers of its workspace resync.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PendingTabRenamed = @import("delivery/PendingTabRenamed.zig");
const client_request = @import("client_request.zig");
const resync_required = @import("resync_required.zig");

/// Commits the tab's new label and replies with the canonical one.
///
/// ```zig
/// try tab_rename.rename(model, session, request);
/// ```
pub fn rename(model: *RuntimeModel, session: *Session, request: core.RenameTab) !void {
    var workspaces = model.workspaceRepository();
    const workspace = workspaces.find(request.location.workspace) orelse {
        return client_request.fail(session, request.request_id, .tab_not_found, "tab not found");
    };
    const renamed = workspace.renameTab(request.location.tab_id, request.label) catch |err| {
        return switch (err) {
            error.TabNotFound => client_request.fail(session, request.request_id, .tab_not_found, "tab not found"),
            error.InvalidTabLabel => client_request.fail(session, request.request_id, .invalid_request, "invalid tab label"),
        };
    };

    model.noteSessionChange();
    model.agents.touch();
    resync_required.notify(model, .{ .origin = session.key, .workspace = renamed.location.workspace });

    const label = renamed.labelSlice();
    var pending: PendingTabRenamed = .{
        .request_id = request.request_id,
        .location = renamed.location,
        .label = undefined,
        .label_len = @intCast(label.len),
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try session.delivery.responses.push(.{ .tab_renamed = pending });
}
