//! Types shared by telar's backend and frontend.
//!
//! This package has no process, PTY or host-terminal ownership. It contains
//! the cell grid that crosses the future IPC boundary and operations over that
//! data. Both sides depend on core. Core depends on neither side.

pub const ui = @import("ui.zig");
pub const select = @import("select.zig");
pub const transport = @import("transport.zig");
pub const schema = @import("schema/messages.zig");
pub const handshake = @import("schema/handshake.zig");
pub const endpoint = @import("endpoint.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const graphics = @import("graphics.zig");
pub const plugin = @import("plugin.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
