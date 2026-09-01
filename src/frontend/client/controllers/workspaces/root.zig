//! Client adapters for workspace lifecycle and synchronization.

pub const workspace_creations = @import("workspace_creations.zig");
pub const workspace_handoffs = @import("workspace_handoffs.zig");
pub const workspace_lists = @import("workspace_lists.zig");
pub const workspace_renames = @import("workspace_renames.zig");
pub const workspace_snapshots = @import("workspace_snapshots.zig");
pub const workspace_transitions = @import("workspace_transitions.zig");

test {
    _ = workspace_creations;
    _ = workspace_handoffs;
    _ = workspace_lists;
    _ = workspace_renames;
    _ = workspace_snapshots;
    _ = workspace_transitions;
}
