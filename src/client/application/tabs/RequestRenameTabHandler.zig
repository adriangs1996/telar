const ModelType = @import("../../model/Model.zig");
const RenameTabOperationGate = @import("RenameTabOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const RequestRenameTab = @import("RequestRenameTab.zig");
const rename_tab = @import("rename_tab.zig");
const RequestRenameTabHandler = @This();

model: *const ModelType,
gate: RenameTabOperationGate,
effects: RenameRequestEffects,

/// Validates the label, resolves the prompt's tab identity and sends one
/// rename intent. Blocked or vanished targets return false without effects.
///
/// ```zig
/// if (!try handler.execute(command)) {
///     return;
/// }
/// ```
pub fn execute(handler: *RequestRenameTabHandler, command: RequestRenameTab) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    try rename_tab.validateLabel(command.label);
    const location = handler.model.tabLocation(command.tab_id) orelse return false;
    try handler.effects.send(handler.effects.context, .{
        .location = location,
        .label = command.label,
    });

    return true;
}
