//! Host-terminal screen state, diffing and frame pacing.

pub const diff = @import("diff.zig");
pub const frame = @import("frame.zig");
pub const pace = @import("pace.zig");
pub const screen = @import("screen.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
