//! Client adapters for configuration and extension flows.

pub const config_reloads = @import("config_reloads.zig");
pub const bar_updates = @import("bar_updates.zig");
pub const lua_actions = @import("lua_actions.zig");
pub const plugin_actions = @import("plugin_actions.zig");

test {
    _ = config_reloads;
    _ = bar_updates;
    _ = lua_actions;
    _ = plugin_actions;
}
