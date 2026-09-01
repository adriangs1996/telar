//! Vertical contract and integration tests for runtime flows.

test {
    _ = @import("acknowledge_agent_test.zig");
    _ = @import("cell_projection_test.zig");
    _ = @import("close_pane_test.zig");
    _ = @import("close_tab_test.zig");
    _ = @import("copy_selection_test.zig");
    _ = @import("create_pane_test.zig");
    _ = @import("create_tab_test.zig");
    _ = @import("create_workspace_test.zig");
    _ = @import("detach_pane_test.zig");
    _ = @import("frame_ack_test.zig");
    _ = @import("graphics_configuration_test.zig");
    _ = @import("graphics_credit_test.zig");
    _ = @import("history_query_test.zig");
    _ = @import("move_tab_test.zig");
    _ = @import("open_pane_test.zig");
    _ = @import("pane_input_test.zig");
    _ = @import("pane_resize_test.zig");
    _ = @import("pane_title_test.zig");
    _ = @import("pane_viewport_test.zig");
    _ = @import("read_pane_test.zig");
    _ = @import("search_pane_test.zig");
    _ = @import("send_pane_text_test.zig");
    _ = @import("rename_tab_test.zig");
    _ = @import("rename_workspace_test.zig");
    _ = @import("request_graphics_snapshot_test.zig");
    _ = @import("request_snapshot_test.zig");
    _ = @import("runtime_state_test.zig");
    _ = @import("runtime_stop_test.zig");
    _ = @import("show_notification_test.zig");
    _ = @import("tab_snapshot_test.zig");
    _ = @import("workspace_snapshot_test.zig");
}
