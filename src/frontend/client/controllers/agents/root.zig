//! Client adapters for agent observations.

pub const agent_navigation = @import("agent_navigation.zig");
pub const agent_snapshots = @import("agent_snapshots.zig");
pub const agent_sounds = @import("agent_sounds.zig");
pub const proxy_status = @import("proxy_status.zig");
pub const system_metrics = @import("system_metrics.zig");

test {
    _ = agent_navigation;
    _ = agent_snapshots;
    _ = agent_sounds;
    _ = proxy_status;
    _ = system_metrics;
}
