const ConfirmWorkspaceHandoffHandler = @This();
const client_model = @import("../../root.zig").model;
const WorkspaceArrivalDelivery = @import("WorkspaceArrivalDelivery.zig");
model: *client_model.Model,
delivery: WorkspaceArrivalDelivery,

/// Commits a fully constructed workspace before delivering its exact
/// operational activation. Delivery failure never rolls the model back.
///
/// ```zig
/// try handler.execute(arrival);
/// ```
pub fn execute(handler: *ConfirmWorkspaceHandoffHandler, arrival: client_model.WorkspaceArrival) !void {
    const activation = try handler.model.arriveWorkspace(arrival);

    try handler.delivery.deliver(handler.delivery.context, activation);
}
