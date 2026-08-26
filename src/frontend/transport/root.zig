//! Connections and handshake on telar's disposable frontend side.

pub const local = @import("local.zig");
pub const handshake = @import("handshake.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
