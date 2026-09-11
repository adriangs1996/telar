const ConfirmWorkspaceCreationHandler = @This();
const client_model = @import("../../root.zig").model;
const WorkspaceCreationDelivery = @import("WorkspaceCreationDelivery.zig");
const ConfirmWorkspaceCreation = @import("ConfirmWorkspaceCreation.zig");
model: *client_model.Model,
delivery: WorkspaceCreationDelivery,

/// Replaces the current projection in one commit before delegating its
/// exact result. Delivery failure never restores the retired workspace.
///
/// ```zig
/// const replacement = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmWorkspaceCreationHandler, command: ConfirmWorkspaceCreation) !client_model.WorkspaceReplacement {
    if (!command.created) {
        return error.UnexpectedRequest;
    }

    const replacement = try handler.model.replaceWorkspace(command.arrival);
    try handler.delivery.deliver(handler.delivery.context, &replacement);

    return replacement;
}
