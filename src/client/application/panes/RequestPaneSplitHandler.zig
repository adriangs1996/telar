const ModelType = @import("../../model/Model.zig");
const SplitPaneOperationGate = @import("SplitPaneOperationGate.zig");
const RequestEffects = @import("RequestEffects.zig");
const RequestPaneSplitType = @import("../../model/RequestPaneSplit.zig");
const PaneSplitPlanType = @import("../../model/PaneSplitPlan.zig");
const RequestPaneSplitHandler = @This();

model: *ModelType,
gate: SplitPaneOperationGate,
effects: RequestEffects,

/// Plans and provisionally resizes one split before sending it. Any local
/// delivery failure restores the exact pre-request size.
///
/// ```zig
/// const plan = try handler.execute(.{ .axis = .horizontal, .area = area });
/// ```
pub fn execute(handler: *RequestPaneSplitHandler, request: RequestPaneSplitType) !?PaneSplitPlanType {
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
