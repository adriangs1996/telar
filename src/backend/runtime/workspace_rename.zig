//! A client renames a workspace; the workspace list and agent labels follow.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");
const commands = @import("../workspace/commands.zig");
const resync_required = @import("resync_required.zig");

/// Commits the new name and replies with the workspace snapshot.
///
/// ```zig
/// try workspace_rename.rename(model, session, request);
/// ```
pub fn rename(model: *RuntimeModel, session: *Session, request: core.RenameWorkspace) !void {
    var workspaces = model.workspaceRepository();
    const renamed = commands.renameWorkspace(&workspaces, request.workspace, request.name) catch |err| {
        return switch (err) {
            error.WorkspaceNotFound => client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found"),
            error.InvalidWorkspaceName => client_request.fail(session, request.request_id, .internal, "could not rename workspace"),
        };
    };

    model.noteSessionChange();
    model.agents.touch();
    resync_required.notify(model, .{ .origin = session.key, .workspace = renamed.location });
    try session.delivery.responses.push(.{ .workspace_snapshot = .{
        .request_id = request.request_id,
        .workspace = renamed.location,
    } });
}
