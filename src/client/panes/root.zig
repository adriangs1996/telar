//! Client-owned pane snapshots and presentation retirement values.

pub const Pane = @import("pane_support.zig").Pane;
pub const Spec = @import("pane_support.zig").Spec;
pub const PresentationCommit = @import("commit.zig").PresentationCommit;
pub const damage = @import("damage.zig");
pub const frame = @import("frame.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
