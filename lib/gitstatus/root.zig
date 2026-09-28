//! Git branch and cleanliness of a working tree, the linked worktree a
//! directory lies in and a worktree's distance from its base, read without
//! libgit.

pub const Status = @import("Status.zig");
pub const probe = @import("probe.zig");
pub const Linked = @import("Linked.zig");
pub const linked_worktree = @import("linked_worktree.zig");
pub const DiffStat = @import("DiffStat.zig");
pub const base_distance = @import("base_distance.zig");

test {
    _ = @import("Status.zig");
    _ = @import("probe.zig");
    _ = @import("linked_worktree.zig");
    _ = @import("base_distance.zig");
}
