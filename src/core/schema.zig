//! Messages shared by every telar frontend and backend.
//!
//! Schema codecs operate on byte slices. They do not know whether a frame
//! arrived through a Unix socket, SSH or a future TLS connection.

pub const handshake = @import("schema/handshake.zig");
// The directory name is an internal migration detail. Public users name the
// negotiated protocol version, which changed when pane frames became compact.
pub const v2 = @import("schema/v1.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
