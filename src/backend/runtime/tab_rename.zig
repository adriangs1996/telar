//! A client renames a tab; other observers of its workspace resync.

const session_checkpoint = @import("session_checkpoint.zig");
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
    model.workspaces.renameTab(request.location, request.label) catch |err| {
        return switch (err) {
            error.TabNotFound => client_request.fail(session, request.request_id, .tab_not_found, "tab not found"),
            error.InvalidTabLabel => client_request.fail(session, request.request_id, .invalid_request, "invalid tab label"),
        };
    };

    session_checkpoint.noteChange(model);
    model.agents.touch();
    resync_required.notify(model, .{ .origin = session.key, .workspace = request.location.workspace });

    const label = model.workspaces.tabLabel(request.location).?;
    var pending: PendingTabRenamed = .{
        .request_id = request.request_id,
        .location = request.location,
        .label = undefined,
        .label_len = @intCast(label.len),
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try session.delivery.responses.push(.{ .tab_renamed = pending });
}
