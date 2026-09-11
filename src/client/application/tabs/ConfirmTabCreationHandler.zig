const ModelType = @import("../../model/Model.zig");
const ConfirmationDelivery = @import("ConfirmationDelivery.zig");
const NewTab = @import("../../model/NewTab.zig");
const TabCreationType = @import("../../model/TabCreation.zig");
const ConfirmTabCreationHandler = @This();

model: *ModelType,
delivery: ConfirmationDelivery,

/// Commits the canonical tab before delegating its exact result.
/// Model failures do not deliver; delivery failures preserve the commit.
///
/// ```zig
/// const creation = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmTabCreationHandler, command: NewTab) !TabCreationType {
    const creation = try handler.model.createTab(command);
    try handler.delivery.deliver(handler.delivery.context, creation);

    return creation;
}
