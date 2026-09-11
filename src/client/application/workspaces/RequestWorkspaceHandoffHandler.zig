const RequestWorkspaceHandoffHandler = @This();
const client_model = @import("../../root.zig").model;
const workspace_handoff_admission = @import("workspace_handoff_admission.zig");
const workspace_handoff_preparation = @import("workspace_handoff_preparation.zig");
const workspace_attachment_retirement = @import("workspace_attachment_retirement.zig");
const workspace_handoff_restoration = @import("workspace_handoff_restoration.zig");
const HandoffRequestEffects = @import("HandoffRequestEffects.zig");
const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
model: *client_model.Model,
admission: workspace_handoff_admission.AdmitWorkspaceHandoffHandler,
preparation: workspace_handoff_preparation.PrepareWorkspaceHandoffHandler,
retirement: workspace_attachment_retirement.RetireWorkspaceAttachmentsHandler,
restoration: workspace_handoff_restoration.RestoreWorkspaceHandoffHandler,
effects: HandoffRequestEffects,

/// Admits one explicit authority, preflights without effects, retires
/// every attachment before the open request, then commits departure. Only
/// post-preflight failure requests canonical attachment restoration.
///
/// ```zig
/// const departure = try handler.execute(command, .requested_departure);
/// ```
pub fn execute(handler: *RequestWorkspaceHandoffHandler, command: WorkspaceHandoff, authority: workspace_handoff_admission.Authority) !client_model.WorkspaceDeparture {
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
