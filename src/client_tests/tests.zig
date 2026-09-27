//! The shared client's integration tests: one client over a real socket
//! pair, driven through `ClientHarness` without a window.
test {
    _ = @import("fixtures.zig");
    _ = @import("pane_splits.zig");
    _ = @import("tab_lifecycle.zig");
    _ = @import("workspace_lifecycle.zig");
}
