const RequestCapacity = @import("RequestCapacity.zig");
const DeliveryCapacity = @import("DeliveryCapacity.zig");
const PendingAttachmentsType = @import("PendingAttachments.zig");
const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");
const PrepareTabCloseHandler = @This();

requests: RequestCapacity,
deliveries: DeliveryCapacity,
pending_attachments: PendingAttachmentsType,

/// Reserves one close request, its recovery identity and every outbound
/// delivery required to retire the exact tab without changing state.
///
/// ```zig
/// try handler.execute(model, location);
/// ```
pub fn execute(handler: *const PrepareTabCloseHandler, model: *const ModelType, location: TabLocationType) !void {
    const plan = try model.planTabDetachment(location);

    try handler.requests.ensure(handler.requests.context, 2);

    const retirement_capacity = tab_attachment_retirement.requiredDeliveryCapacity(
        &plan,
        handler.pending_attachments,
    );
    const required_capacity = 1 + retirement_capacity;
    if (required_capacity > handler.deliveries.available(handler.deliveries.context)) {
        return error.ClientOutboxFull;
    }
}
