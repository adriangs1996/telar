const ConfirmTabMoveHandler = @This();
const client_model = @import("../../root.zig").model;
const ConfirmTabMove = @import("ConfirmTabMove.zig");
model: *client_model.Model,

/// Commits the canonical runtime position. A repeated position is a
/// semantic no-op and leaves the model version unchanged.
///
/// ```zig
/// const change = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabMoveHandler, command: ConfirmTabMove) !client_model.Change {
    return handler.model.applyTabPosition(command.location, command.position);
}
