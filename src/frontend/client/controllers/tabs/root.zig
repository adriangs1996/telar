//! Client adapters for tab lifecycle and synchronization.

pub const tab_attachments = @import("tab_attachments.zig");
pub const tab_closures = @import("tab_closures.zig");
pub const tab_creations = @import("tab_creations.zig");
pub const tab_moves = @import("tab_moves.zig");
pub const tab_renames = @import("tab_renames.zig");
pub const tab_selections = @import("tab_selections.zig");
pub const tab_snapshots = @import("tab_snapshots.zig");

test {
    _ = tab_attachments;
    _ = tab_closures;
    _ = tab_creations;
    _ = tab_moves;
    _ = tab_renames;
    _ = tab_selections;
    _ = tab_snapshots;
}
