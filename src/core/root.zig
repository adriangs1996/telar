//! Types shared by telar's backend and frontend.
//!
//! This package has no process, PTY or host-terminal ownership. It contains
//! the cell grid that crosses the future IPC boundary and operations over that
//! data. Both sides depend on core. Core depends on neither side.

pub const ui = @import("ui/root.zig");
pub const select = @import("select.zig");
pub const transport = @import("transport/root.zig");
pub const schema = @import("schema/root.zig");
pub const handshake = @import("schema/handshake.zig");
pub const agent_manifest = @import("agent_manifest.zig");
pub const history_filter = @import("history_filter.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const link = @import("link.zig");
pub const endpoint = transport.endpoint;
pub const diagnostics = @import("diagnostics.zig");
pub const graphics = @import("graphics.zig");
pub const plugin = @import("plugin.zig");
pub const fixed_index = @import("fixed_index.zig");
pub const proxy = @import("proxy.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
