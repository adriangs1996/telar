//! Client model invariant tests grouped by semantic state.

test {
    _ = @import("configuration_and_host.zig");
    _ = @import("input_and_frames.zig");
    _ = @import("observations.zig");
    _ = @import("panes.zig");
    _ = @import("tabs.zig");
    _ = @import("workspaces.zig");
}
