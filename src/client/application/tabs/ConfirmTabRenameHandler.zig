const ConfirmTabRenameHandler = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("rename_tab.zig");
model: *client_model.Model,

/// Commits the canonical runtime label. Repeating the current label leaves
/// the model version unchanged.
///
/// ```zig
/// const change = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabRenameHandler, command: source_namespace.ConfirmTabRename) !client_model.Change {
    return handler.model.renameTab(command);
}
