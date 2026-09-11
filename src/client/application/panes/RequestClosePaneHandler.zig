const RequestClosePaneHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneOperationGate = @import("ClosePanePaneOperationGate.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const source_namespace = @import("close_pane.zig");
model: *const client_model.Model,
gate: PaneOperationGate,
effects: CloseRequestEffects,

/// Sends one close request for the active attached pane. The request does
/// not mutate the model; `pane_exited` is the authoritative transition.
///
/// ```zig
/// const closure = try handler.execute() orelse return;
/// ```
pub fn execute(handler: *RequestClosePaneHandler) !?source_namespace.PaneClosure {
    if (handler.gate.pending(handler.gate.context)) {
        return null;
    }

    const closure = handler.model.planPaneClosure() orelse return null;
    try handler.effects.send(handler.effects.context, closure);

    return closure;
}
