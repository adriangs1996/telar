//! Connection acceptance and handshake on the long-lived side of telar.

pub const local = @import("transport/local.zig");
pub const handshake = @import("transport/handshake.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
