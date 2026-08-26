//! Host input parsing, routing and semantic actions.

pub const action = @import("action.zig");
pub const copy_mode = @import("copy_mode.zig");
pub const edit = @import("edit.zig");
pub const host = @import("host.zig");
pub const keybind = @import("keybind.zig");
pub const mouse_protocol = @import("mouse_protocol.zig");

// Preserve the former `frontend.input` surface while making input a namespace.
pub const Key = host.Key;
pub const Modes = host.Modes;
pub const encodeKey = host.encodeKey;
pub const encodePaste = host.encodePaste;

test {
    @import("std").testing.refAllDecls(@This());
}
