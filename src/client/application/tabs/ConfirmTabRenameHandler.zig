const ModelType = @import("../../model/Model.zig");
const RenameTab = @import("../../model/RenameTab.zig");
const types = @import("../../model/types.zig");
const ConfirmTabRenameHandler = @This();

model: *ModelType,

/// Commits the canonical runtime label. Repeating the current label leaves
/// the model version unchanged.
///
/// ```zig
/// const change = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabRenameHandler, command: RenameTab) !types.Change {
    return handler.model.renameTab(command);
}
