const ConfirmTabCreationHandler = @This();
const client_model = @import("../../root.zig").model;
const ConfirmationDelivery = @import("ConfirmationDelivery.zig");
const source_namespace = @import("create_tab.zig");
model: *client_model.Model,
delivery: ConfirmationDelivery,

/// Commits the canonical tab before delegating its exact result.
/// Model failures do not deliver; delivery failures preserve the commit.
///
/// ```zig
/// const creation = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabCreationHandler, command: source_namespace.ConfirmTabCreation) !client_model.TabCreation {
    const creation = try handler.model.createTab(command);
    try handler.delivery.deliver(handler.delivery.context, creation);

    return creation;
}
