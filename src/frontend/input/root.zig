//! Host input parsing, routing and semantic actions.

/// Maximum encoded input chunk retained by the client outbox.
pub const max_encoded_bytes: usize = 8 * 1024;

pub const action = @import("telar-client").input.action;
pub const copy_mode = @import("telar-client").input.copy_mode;
pub const edit = @import("telar-client").input.edit;
pub const host = @import("host.zig");
pub const keybind = @import("keybind.zig");
pub const key_lease = @import("telar-client").input.key_lease;
pub const mouse_protocol = @import("telar-client").input.mouse_protocol;

// Preserve the former `frontend.input` surface while making input a namespace.
pub const Key = host.Key;
pub const Modes = host.Modes;
pub const encodeKey = host.encodeKey;
pub const encodePaste = host.encodePaste;

test {
    @import("std").testing.refAllDecls(@This());
}
