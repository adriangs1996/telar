//! Connection acceptance and handshake on the long-lived side of telar.

pub const local = @import("local.zig");
pub const handshake = @import("handshake.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
