const ModelType = @import("../../model/Model.zig");
const WorkspaceArrivalDelivery = @import("WorkspaceArrivalDelivery.zig");
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const ConfirmWorkspaceHandoffHandler = @This();

model: *ModelType,
delivery: WorkspaceArrivalDelivery,

/// Commits a fully constructed workspace before delivering its exact
/// operational activation. Delivery failure never rolls the model back.
///
/// ```zig
/// try handler.execute(arrival);
/// ```
pub fn execute(handler: *ConfirmWorkspaceHandoffHandler, arrival: WorkspaceArrivalType) !void {
    const activation = try handler.model.arriveWorkspace(arrival);

    try handler.delivery.deliver(handler.delivery.context, activation);
}
