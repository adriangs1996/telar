//! Messages shared by every telar frontend and backend.
//!
//! Schema codecs operate on byte slices. They do not know whether a frame
//! arrived through a Unix socket, SSH or a future TLS connection.

pub const handshake = @import("schema/handshake.zig");
pub const v1 = @import("schema/v1.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
