//! Public namespace for one long-lived Telar runtime.

const std_module = @import("std");
const Runtime = @import("Runtime.zig");

test "Runtime owns its endpoint until the injected stop dependency fires" {
    const std = std_module;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(
        &endpoint_buffer,
        "{s}/runtime-contract.sock",
        .{directory_buffer[0..directory_len]},
    );
    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{
            .endpoint = endpoint,
            .environment = std.testing.environ,
            .stop = &stop,
        },
    });
    defer runtime.deinit();

    try stop.putOneUncancelable(io, 0);
    try runtime.run();
    runtime.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
    );
}

test {
    std_module.testing.refAllDecls(@This());
    _ = @import("tests/acknowledge_agent_test.zig");
    _ = @import("tests/cell_projection_test.zig");
    _ = @import("tests/close_pane_test.zig");
    _ = @import("tests/close_tab_test.zig");
    _ = @import("tests/copy_selection_test.zig");
    _ = @import("tests/create_pane_test.zig");
    _ = @import("tests/create_tab_test.zig");
    _ = @import("tests/create_workspace_test.zig");
    _ = @import("tests/detach_pane_test.zig");
    _ = @import("tests/frame_ack_test.zig");
    _ = @import("tests/graphics_configuration_test.zig");
    _ = @import("tests/graphics_credit_test.zig");
    _ = @import("tests/history_query_test.zig");
    _ = @import("tests/move_tab_test.zig");
    _ = @import("tests/open_pane_test.zig");
    _ = @import("tests/pane_input_test.zig");
    _ = @import("tests/pane_resize_test.zig");
    _ = @import("tests/pane_title_test.zig");
    _ = @import("tests/pane_viewport_test.zig");
    _ = @import("tests/performance_isolation_test.zig");
    _ = @import("tests/read_pane_test.zig");
    _ = @import("tests/rename_tab_test.zig");
    _ = @import("tests/rename_workspace_test.zig");
    _ = @import("tests/request_graphics_snapshot_test.zig");
    _ = @import("tests/request_snapshot_test.zig");
    _ = @import("tests/runtime_state_test.zig");
    _ = @import("tests/runtime_stop_test.zig");
    _ = @import("tests/search_pane_test.zig");
    _ = @import("tests/send_pane_text_test.zig");
    _ = @import("tests/shared_frame_test.zig");
    _ = @import("tests/show_notification_test.zig");
    _ = @import("tests/tab_snapshot_test.zig");
    _ = @import("tests/workspace_snapshot_test.zig");
}
