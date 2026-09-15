const ModelType = @import("../../model/Model.zig");
const MoveTabOperationGate = @import("MoveTabOperationGate.zig");
const MoveRequestEffects = @import("MoveRequestEffects.zig");
const RequestTabMove = @import("RequestTabMove.zig");
const RequestTabMoveHandler = @This();

model: *const ModelType,
gate: MoveTabOperationGate,
effects: MoveRequestEffects,

/// Sends one move intent for the active tab without changing its local
/// position. Blocked requests and an empty projection have no effects.
///
/// ```zig
/// if (!try handler.execute(.{ .direction = .previous })) {
///     return;
/// }
/// ```
pub fn execute(handler: *RequestTabMoveHandler, request: RequestTabMove) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    const location = request.location orelse handler.model.activeTabLocation() orelse return false;
    const workspace = handler.model.workspace.workspace orelse return false;
    if (!@import("std").meta.eql(workspace, location.workspace) or handler.model.workspace.indexOf(location.tab_id) == null) {
        return false;
    }

    if (request.relative_to) |anchor| {
        if (anchor == location.tab_id or handler.model.workspace.indexOf(anchor) == null) {
            return false;
        }
    }

    try handler.effects.send(handler.effects.context, .{
        .location = location,
        .direction = request.direction,
        .relative_to = request.relative_to,
    });

    return true;
}
