const ModelType = @import("../../model/Model.zig");
const ConfirmTabMove = @import("ConfirmTabMove.zig");
const types = @import("../../model/types.zig");
const ConfirmTabMoveHandler = @This();

model: *ModelType,

/// Commits the canonical runtime position. A repeated position is a
/// semantic no-op and leaves the model version unchanged.
///
/// ```zig
/// const change = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabMoveHandler, command: ConfirmTabMove) !types.Change {
    return handler.model.applyTabPosition(command.location, command.position);
}
