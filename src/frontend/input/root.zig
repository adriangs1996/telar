//! Terminal decoding and routing adapters for semantic client input.
const input = @import("telar-client").input;

pub const max_encoded_bytes = input.max_encoded_bytes;
pub const action = input.action;
pub const copy_mode = input.copy_mode;
pub const edit = input.edit;
pub const encoding = input.encoding;
pub const keybind = @import("keybind.zig");
pub const key_lease = input.key_lease;
pub const mouse_protocol = input.mouse_protocol;
pub const Key = input.Key;
pub const Modes = input.Modes;
pub const encodeKey = input.encodeKey;
pub const encodePaste = input.encodePaste;

test {
    _ = @import("host_tests.zig");
    @import("std").testing.refAllDecls(@This());
}
