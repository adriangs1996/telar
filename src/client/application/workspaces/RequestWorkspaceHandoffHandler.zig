const ModelType = @import("../../model/Model.zig");
const AdmitWorkspaceHandoffHandlerType = @import("AdmitWorkspaceHandoffHandler.zig");
const PrepareWorkspaceHandoffHandlerType = @import("PrepareWorkspaceHandoffHandler.zig");
const RetireWorkspaceAttachmentsHandlerType = @import("RetireWorkspaceAttachmentsHandler.zig");
const RestoreWorkspaceHandoffHandlerType = @import("RestoreWorkspaceHandoffHandler.zig");
const HandoffRequestEffects = @import("HandoffRequestEffects.zig");
const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
const workspace_handoff_admission = @import("workspace_handoff_admission.zig");
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const RequestWorkspaceHandoffHandler = @This();

model: *ModelType,
admission: AdmitWorkspaceHandoffHandlerType,
preparation: PrepareWorkspaceHandoffHandlerType,
retirement: RetireWorkspaceAttachmentsHandlerType,
restoration: RestoreWorkspaceHandoffHandlerType,
effects: HandoffRequestEffects,

/// Admits one explicit authority, preflights without effects, retires
/// every attachment before the open request, then commits departure. Only
/// post-preflight failure requests canonical attachment restoration.
///
/// ```zig
/// const departure = try handler.execute(command, .requested_departure);
/// ```
pub fn execute(handler: *RequestWorkspaceHandoffHandler, command: WorkspaceHandoff, authority: workspace_handoff_admission.Authority) !WorkspaceDepartureType {
    try handler.admission.execute(authority);

    try handler.preparation.execute();

    handler.retirement.execute() catch |err| {
        _ = handler.restoration.execute(handler.model) catch {};
        return err;
    };
    handler.effects.send(handler.effects.context, command) catch |err| {
        _ = handler.restoration.execute(handler.model) catch {};
        return err;
    };

    const departure = handler.model.departWorkspace();
    handler.effects.release(handler.effects.context, &departure);

    return departure;
}
