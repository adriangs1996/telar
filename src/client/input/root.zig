//! Semantic input values independent of host parsing and rendering.

pub const Key = @import("key.zig").Key;
pub const Char = @import("key.zig").Char;
pub const Mouse = @import("key.zig").Mouse;

pub const edit = @import("edit.zig");
pub const copy_mode = @import("copy_mode.zig");
pub const key_lease = @import("key_lease.zig");
pub const action = @import("action.zig");

pub const chord = @import("chord.zig");
pub const parseKey = chord.parseKey;

test {
    @import("std").testing.refAllDecls(@This());
}
