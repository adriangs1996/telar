//! Concrete adapters that bind application flows to one Client instance.

pub const agents = @import("agents/root.zig");
pub const configuration = @import("configuration/root.zig");
pub const host = @import("host/root.zig");
pub const input = @import("input/root.zig");
pub const notifications = @import("notifications/root.zig");
pub const panes = @import("panes/root.zig");
pub const session = @import("session/root.zig");
pub const tabs = @import("tabs/root.zig");
pub const workspaces = @import("workspaces/root.zig");

test {
    _ = agents;
    _ = configuration;
    _ = host;
    _ = input;
    _ = notifications;
    _ = panes;
    _ = session;
    _ = tabs;
    _ = workspaces;
}
