const ModelType = @import("../../model/Model.zig");
const RequestCapacity = @import("RequestCapacity.zig");
const DeliveryCapacity = @import("DeliveryCapacity.zig");
const PendingAttachmentsType = @import("../tabs/PendingAttachments.zig");
const tab_attachment_retirement = @import("../tabs/tab_attachment_retirement.zig");
const PrepareWorkspaceHandoffHandler = @This();

model: *ModelType,
requests: RequestCapacity,
deliveries: DeliveryCapacity,
pending_attachments: PendingAttachmentsType,

/// Reserves one open request, its recovery identity and every outbound
/// delivery required to retire the current workspace without effects.
///
/// ```zig
/// try handler.execute();
/// ```
pub fn execute(handler: *const PrepareWorkspaceHandoffHandler) !void {
    try handler.requests.ensure(handler.requests.context, 2);

    const required_capacity = try handler.requiredDeliveryCapacity();
    if (required_capacity > handler.deliveries.available(handler.deliveries.context)) {
        return error.ClientOutboxFull;
    }
}

fn requiredDeliveryCapacity(handler: *const PrepareWorkspaceHandoffHandler) !usize {
    var required: usize = 1;

    var tabs = handler.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        const plan = try handler.model.planTabDetachment(tab.location);
        required += tab_attachment_retirement.requiredDeliveryCapacity(
            &plan,
            handler.pending_attachments,
        );
    }

    return required;
}
