const RequestTabCreationHandler = @This();
const client_model = @import("../../root.zig").model;
const TabOperationGate = @import("CreateTabTabOperationGate.zig");
const CreationRequestEffects = @import("CreationRequestEffects.zig");
const RequestTabCreation = @import("RequestTabCreation.zig");
const source_namespace = @import("create_tab.zig");
const TabCreationIntent = @import("TabCreationIntent.zig");
model: *const client_model.Model,
gate: TabOperationGate,
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

    try source_namespace.validateLabel(request.label);
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
