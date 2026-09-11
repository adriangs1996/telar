//! Semantic input values independent of host parsing and rendering.

pub const Key = @import("key.zig").Key;
pub const Char = @import("key.zig").Char;
pub const Mouse = @import("key.zig").Mouse;
pub const action = @import("action.zig");
pub const chord = @import("chord.zig");
pub const copy_mode = @import("copy_mode.zig");
pub const edit = @import("edit.zig");
pub const encoding = @import("encoding.zig");
pub const hints = @import("hints.zig");
pub const key_lease = @import("key_lease.zig");
pub const keybind = @import("keybind.zig");
pub const mouse_protocol = @import("mouse_protocol.zig");
pub const parseKey = chord.parseKey;
pub const Modes = encoding.Modes;
pub const encodeKey = encoding.encodeKey;
pub const encodePaste = encoding.encodePaste;
pub const max_encoded_bytes: usize = 8 * 1024;

test {
    _ = @import("routing_tests.zig");
    _ = @import("encoding_tests.zig");
    @import("std").testing.refAllDecls(@This());
}
