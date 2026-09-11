const ModelType = @import("../../model/Model.zig");
const CreateTabOperationGate = @import("CreateTabOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const RequestTabCreation = @import("RequestTabCreation.zig");
const create_tab = @import("create_tab.zig");
const TabCreationIntent = @import("TabCreationIntent.zig");
const RequestTabCreationHandler = @This();

model: *const ModelType,
gate: CreateTabOperationGate,
effects: CreationRequestEffects,

/// Plans a tab launch from the attached focused pane and delivers one
/// intent without changing the semantic model.
///
/// ```zig
/// if (!try handler.execute(.{})) return;
/// ```
pub fn execute(handler: *RequestTabCreationHandler, request: RequestTabCreation) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    try create_tab.validateLabel(request.label);
    const plan = handler.model.planTabCreation() orelse return false;
    const intent: TabCreationIntent = .{
        .workspace = plan.workspace,
        .cwd_source = plan.cwd_source,
        .label = request.label,
        .arguments = request.arguments,
    };
    try handler.effects.send(handler.effects.context, intent);

    return true;
}
