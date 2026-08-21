//! The long-lived side of telar.
//!
//! The backend owns processes, PTYs and terminal emulation. It may produce
//! core data for a frontend, but it never imports frontend code.

pub const pty = @import("pty.zig");
pub const blit = @import("blit.zig");
pub const transport = @import("transport.zig");
pub const runtime = @import("runtime.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
