//! Client integration proof grouped by user-visible flow.

test {
    _ = @import("transport.zig");
    _ = @import("presentation.zig");
    _ = @import("synchronization.zig");
    _ = @import("input.zig");
    _ = @import("pane_lifecycle.zig");
    _ = @import("workspace_lifecycle.zig");
    _ = @import("tab_lifecycle.zig");
    _ = @import("pane_updates.zig");
    _ = @import("notifications_and_agents.zig");
    _ = @import("graphics_and_clipboard.zig");
    _ = @import("history_browser.zig");
    _ = @import("configuration.zig");
    _ = @import("host_interaction.zig");
    _ = @import("renaming_and_telemetry.zig");
}
