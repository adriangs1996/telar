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

    const location = handler.model.activeTabLocation() orelse return false;
    try handler.effects.send(handler.effects.context, .{
        .location = location,
        .direction = request.direction,
    });

    return true;
}
