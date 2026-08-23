//! The disposable side of telar.
//!
//! The frontend owns the real terminal, frame pacing and interactive UI state.
//! It consumes core data and never reaches into backend process state.

const core = @import("telar-core");

pub const ui = @import("ui.zig");
pub const select = core.select;
pub const term = @import("term.zig");
pub const frame = @import("frame.zig");
pub const pace = @import("pace.zig");
pub const edit = @import("edit.zig");
pub const theme = @import("theme.zig");
pub const kitty = @import("kitty.zig");
pub const keybind = @import("keybind.zig");
pub const layout = @import("layout.zig");
pub const multiplexer = @import("multiplexer.zig");
pub const tabs = @import("tabs.zig");
pub const client_ui = @import("client_ui.zig");
pub const platform = @import("platform.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
