//! Connections and handshake on telar's disposable frontend side.

pub const local = @import("transport/local.zig");
pub const handshake = @import("transport/handshake.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
