const PrepareWorkspaceHandoffHandler = @This();
const client_model = @import("../../root.zig").model;
const RequestCapacity = @import("RequestCapacity.zig");
const DeliveryCapacity = @import("DeliveryCapacity.zig");
const tab_attachment_retirement = @import("../tabs/root.zig").tab_attachment_retirement;
model: *client_model.Model,
requests: RequestCapacity,
deliveries: DeliveryCapacity,
pending_attachments: tab_attachment_retirement.PendingAttachments,

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
