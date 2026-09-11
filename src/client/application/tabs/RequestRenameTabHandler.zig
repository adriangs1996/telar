const RequestRenameTabHandler = @This();
const client_model = @import("../../root.zig").model;
const TabOperationGate = @import("RenameTabTabOperationGate.zig");
const RenameRequestEffects = @import("RenameRequestEffects.zig");
const RequestRenameTab = @import("RequestRenameTab.zig");
const source_namespace = @import("rename_tab.zig");
model: *const client_model.Model,
gate: TabOperationGate,
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

    try source_namespace.validateLabel(command.label);
    const location = handler.model.tabLocation(command.tab_id) orelse return false;
    try handler.effects.send(handler.effects.context, .{
        .location = location,
        .label = command.label,
    });

    return true;
}
