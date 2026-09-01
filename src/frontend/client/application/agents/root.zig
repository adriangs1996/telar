//! Agent observation flows owned by the client application.

pub const agent_navigation = @import("agent_navigation.zig");
pub const agent_snapshot = @import("agent_snapshot.zig");
pub const agent_snapshot_delivery = @import("agent_snapshot_delivery.zig");
pub const agent_sound = @import("agent_sound.zig");
pub const proxy_status = @import("proxy_status.zig");
pub const proxy_status_delivery = @import("proxy_status_delivery.zig");

test {
    _ = agent_navigation;
    _ = agent_snapshot;
    _ = agent_snapshot_delivery;
    _ = agent_sound;
    _ = proxy_status;
    _ = proxy_status_delivery;
}
