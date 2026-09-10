//! Semantic input values independent of host parsing and rendering.

pub const Key = @import("key.zig").Key;
pub const Char = @import("key.zig").Char;
pub const Mouse = @import("key.zig").Mouse;

test {
    @import("std").testing.refAllDecls(@This());
}
