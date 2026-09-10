//! Shared client behavior. No terminal, window, or renderer dependencies.

pub const panes = @import("panes/root.zig");
pub const input = @import("input/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
