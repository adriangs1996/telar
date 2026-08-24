//! The disposable side of telar.
//!
//! The frontend owns the real terminal, frame pacing and interactive UI state.
//! It consumes core data and never reaches into backend process state.

const core = @import("telar-core");

pub const ui = @import("ui.zig");
pub const select = core.select;
pub const term = @import("term.zig");
pub const diff = @import("diff.zig");
pub const frame = @import("frame.zig");
pub const pace = @import("pace.zig");
pub const edit = @import("edit.zig");
pub const theme = @import("theme.zig");
pub const kitty = @import("kitty.zig");
pub const keybind = @import("keybind.zig");
pub const action = @import("action.zig");
pub const input = @import("input.zig");
pub const lua_config = @import("lua_config.zig");
pub const plugin_broker = @import("plugin_broker.zig");
pub const plugin_protocol = @import("plugin_protocol.zig");
pub const plugin_worker = @import("plugin_worker.zig");
pub const layout = @import("layout.zig");
pub const multiplexer = @import("multiplexer.zig");
pub const tabs = @import("tabs.zig");
pub const client_ui = @import("client_ui.zig");
pub const platform = @import("platform.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");
pub const client_outbox = @import("client_outbox.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
