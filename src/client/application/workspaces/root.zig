//! Workspace lifecycle and synchronization flows owned by the client application.

pub const create_workspace = @import("create_workspace.zig");
pub const rename_workspace = @import("rename_workspace.zig");
pub const workspace_arrival_planning = @import("workspace_arrival_planning.zig");
pub const workspace_attachment_retirement = @import("workspace_attachment_retirement.zig");
pub const workspace_creation_delivery = @import("workspace_creation_delivery.zig");
pub const workspace_handoff = @import("workspace_handoff.zig");
pub const workspace_handoff_admission = @import("workspace_handoff_admission.zig");
pub const workspace_handoff_preparation = @import("workspace_handoff_preparation.zig");
pub const workspace_handoff_restoration = @import("workspace_handoff_restoration.zig");
pub const workspace_handoff_targeting = @import("workspace_handoff_targeting.zig");
pub const workspace_list_snapshot = @import("workspace_list_snapshot.zig");
pub const workspace_snapshot = @import("workspace_snapshot.zig");
pub const workspace_snapshot_delivery = @import("workspace_snapshot_delivery.zig");
pub const workspace_transition_delivery = @import("workspace_transition_delivery.zig");

test {
    _ = create_workspace;
    _ = rename_workspace;
    _ = workspace_arrival_planning;
    _ = workspace_attachment_retirement;
    _ = workspace_creation_delivery;
    _ = workspace_handoff;
    _ = workspace_handoff_admission;
    _ = workspace_handoff_preparation;
    _ = workspace_handoff_restoration;
    _ = workspace_handoff_targeting;
    _ = workspace_list_snapshot;
    _ = workspace_snapshot;
    _ = workspace_snapshot_delivery;
    _ = workspace_transition_delivery;
}
