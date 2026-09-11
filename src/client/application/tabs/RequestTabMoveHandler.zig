const RequestTabMoveHandler = @This();
const client_model = @import("../../root.zig").model;
const TabOperationGate = @import("MoveTabTabOperationGate.zig");
const MoveRequestEffects = @import("MoveRequestEffects.zig");
const RequestTabMove = @import("RequestTabMove.zig");
model: *const client_model.Model,
gate: TabOperationGate,
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
