//! A client moves a tab within its workspace and receives the absolute
//! position the runtime committed.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");
const commands = @import("../workspace/commands.zig");
const resync_required = @import("resync_required.zig");

/// Reorders the tab and replies with its committed position.
///
/// ```zig
/// try tab_move.move(model, session, request);
/// ```
pub fn move(model: *RuntimeModel, session: *Session, request: core.MoveTab) !void {
    var workspaces = model.workspaceRepository();
    const moved = commands.moveTab(
        &workspaces,
        request.location,
        .{ .direction = request.direction, .relative_to = request.relative_to },
    ) catch |err| {
        return switch (err) {
            error.WorkspaceNotFound => client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found"),
            error.TabNotFound => client_request.fail(session, request.request_id, .tab_not_found, "tab not found"),
        };
    };

    model.noteSessionChange();
    resync_required.notify(model, .{ .origin = session.key, .workspace = moved.location.workspace });
    try session.delivery.responses.push(.{ .tab_moved = .{
        .request_id = request.request_id,
        .location = moved.location,
        .position = moved.position,
    } });
}
