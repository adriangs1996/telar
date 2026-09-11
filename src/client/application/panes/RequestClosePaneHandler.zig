const ModelType = @import("../../model/Model.zig");
const ClosePaneOperationGate = @import("ClosePaneOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const PaneClosureType = @import("../../model/PaneClosure.zig");
const RequestClosePaneHandler = @This();

model: *const ModelType,
gate: ClosePaneOperationGate,
effects: CloseRequestEffects,

/// Sends one close request for the active attached pane. The request does
/// not mutate the model; `pane_exited` is the authoritative transition.
///
/// ```zig
/// const closure = try handler.execute() orelse return;
/// ```
pub fn execute(handler: *RequestClosePaneHandler) !?PaneClosureType {
    if (handler.gate.pending(handler.gate.context)) {
        return null;
    }

    const closure = handler.model.planPaneClosure() orelse return null;
    try handler.effects.send(handler.effects.context, closure);

    return closure;
}
