//! The shared client's integration tests: one client over a real socket
//! pair, driven through `ClientHarness` without a window.
test {
    _ = @import("fixtures.zig");
    _ = @import("pane_lifecycle.zig");
    _ = @import("pane_splits.zig");
    _ = @import("notifications_and_agents.zig");
    _ = @import("renaming_and_telemetry.zig");
    _ = @import("history_browser.zig");
    _ = @import("path_picker.zig");
    _ = @import("synchronization.zig");
    _ = @import("transport.zig");
    _ = @import("pane_updates.zig");
    _ = @import("input.zig");
    _ = @import("input_operations.zig");
    _ = @import("host_interaction.zig");
    _ = @import("mouse_selection.zig");
    _ = @import("presentation.zig");
    _ = @import("cache_trace.zig");
}
