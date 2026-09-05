//! Public entrypoints for the command-specific argument grammars.

pub const notification = @import("notification.zig");
pub const history = @import("history.zig");
pub const agent = @import("agent.zig");
pub const pane = @import("pane.zig");
pub const workspace = @import("workspace.zig");
pub const hook = @import("hook.zig");
pub const integration = @import("integration.zig");
pub const proxy = @import("proxy.zig");
pub const api = @import("api.zig");
pub const server = @import("server.zig");
pub const values = @import("values.zig");
pub const config = @import("config.zig");
pub const plugin_worker = @import("plugin_worker.zig");
pub const tap_worker = @import("tap_worker.zig");
pub const plugin = @import("plugin.zig");
pub const run = @import("run.zig");

test {
    _ = @import("cursor.zig");
}
