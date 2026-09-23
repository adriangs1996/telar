const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Client = @import("AttachedClient.zig");
/// Preserves native reader admission and terminal copy-mode behavior.
/// Example: `try agentReaders(enterCopyMode);`
pub fn agentReaders(comptime enter: fn (*Client) bool) !void {
    const app = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(app);
    app.* = undefined;
    app.model = data.ClientModel.init(std.testing.allocator, true);
    defer app.model.deinit();
    const pane_id: core.PaneId = @enumFromInt(1);
    try data.workspace_handoff.bootstrap(&app.model, 
        .{
            .pane_id = pane_id,
            .location = .{
                .workspace = .{
                    .workspace = @enumFromInt(1),
                },
                .tab_id = @enumFromInt(1),
            },
            .size = .{
                .cols = 10,
                .rows = 5,
            },
        },
    );
    const pane = app.model.panes.find(pane_id).?;
    pane.kind = .agent;
    var received: ?core.PaneId = null;
    app.host_input_source = .{
        .context = &received,
        .resume_read_fn = undefined,
        .route_prompt_bytes_fn = undefined,
        .adopt_bindings_fn = undefined,
    };
    const revision = app.model.copy_revision;
    try std.testing.expect(!enter(app));
    try std.testing.expect(!app.copyModeActive());
    try std.testing.expect(app.model.copy_state == null);
    app.host_input_source.enter_thread_copy_mode_fn = captureThreadCopyMode;
    app.host_input_source.thread_copy_mode_active_fn = threadCopyModeActive;
    app.host_input_source.leave_thread_copy_mode_fn = leaveThreadCopyMode;
    try std.testing.expect(enter(app));
    try std.testing.expectEqual(pane_id, received.?);
    try std.testing.expect(app.model.copy_state == null);
    try std.testing.expectEqual(revision, app.model.copy_revision);
    try std.testing.expect(app.copyModeActive());
    try std.testing.expectEqual(.exited, try app.leaveCopyMode());
    try std.testing.expect(!app.copyModeActive());
    try std.testing.expect(received == null);
    pane.attached = false;
    try std.testing.expect(!enter(app));
    pane.attached = true;
    app.model.name_prompt.begin(.create_workspace);
    try std.testing.expect(!enter(app));
    app.model.name_prompt = .{};
    app.model.pane_paste = .{
        .pane_id = pane_id,
        .bracketed_paste = false,
    };
    try std.testing.expect(!enter(app));
    app.model.pane_paste = null;
    try std.testing.expect(received == null);
    pane.kind = .terminal;
    try std.testing.expect(enter(app));
    try std.testing.expect(app.model.copyModeActive());
    try std.testing.expect(received == null);
}

fn captureThreadCopyMode(context: *anyopaque, pane_id: core.PaneId) bool {
    const received: *?core.PaneId = @ptrCast(@alignCast(context));
    received.* = pane_id;
    return true;
}

fn threadCopyModeActive(context: *anyopaque) bool {
    const received: *?core.PaneId = @ptrCast(@alignCast(context));
    return received.* != null;
}

fn leaveThreadCopyMode(context: *anyopaque) bool {
    const received: *?core.PaneId = @ptrCast(@alignCast(context));
    const changed = received.* != null;
    received.* = null;
    return changed;
}
