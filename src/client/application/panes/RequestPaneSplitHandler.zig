const RequestPaneSplitHandler = @This();
const client_model = @import("../../root.zig").model;
const PaneOperationGate = @import("SplitPanePaneOperationGate.zig");
const RequestEffects = @import("RequestEffects.zig");
const source_namespace = @import("split_pane.zig");
model: *client_model.Model,
gate: PaneOperationGate,
effects: RequestEffects,

/// Plans and provisionally resizes one split before sending it. Any local
/// delivery failure restores the exact pre-request size.
///
/// ```zig
/// const plan = try handler.execute(.{ .axis = .horizontal, .area = area });
/// ```
pub fn execute(handler: *RequestPaneSplitHandler, request: client_model.RequestPaneSplit) !?source_namespace.PaneSplitPlan {
    if (handler.gate.pending(handler.gate.context)) {
        return null;
    }

    const plan = handler.model.planPaneSplit(request) orelse return null;
    handler.effects.resize(handler.effects.context, plan.provisional_resize) catch |err| {
        try handler.effects.resize(handler.effects.context, plan.restore_resize);
        return err;
    };
    handler.effects.send(handler.effects.context, plan) catch |err| {
        try handler.effects.resize(handler.effects.context, plan.restore_resize);
        return err;
    };

    return plan;
}
