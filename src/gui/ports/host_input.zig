const core = @import("telar-core");
const thread_selection = @import("../widgets/interaction/thread_selection.zig");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const thread_items = @import("../widgets/interaction/thread_items.zig");

/// Example: `gui.app.host_input_source = host_input.port(gui);`
pub fn port(gui: *GuiClient) client.HostInputSource {
    return .{ .context = gui, .route_prompt_bytes_fn = promptBytes, .enter_thread_copy_mode_fn = enterCopy, .thread_copy_mode_active_fn = copyActive, .leave_thread_copy_mode_fn = leaveCopy, .set_thread_expansion_fn = setExpansion };
}

fn promptBytes(context: *anyopaque, bytes: []const u8) !void {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    const app = &gui.app;
    _ = try app.inputPrompt(
        .{
            .paste_text = bytes,
        },
    );
}

fn enterCopy(context: *anyopaque, pane_id: core.PaneId) bool {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    return thread_selection.enter(gui, pane_id);
}

fn copyActive(context: *anyopaque) bool {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    return thread_selection.active(gui);
}

fn leaveCopy(context: *anyopaque) bool {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    return thread_selection.leave(gui);
}

fn setExpansion(context: *anyopaque, request: client.ThreadExpansion) !void {
    const gui: *GuiClient = @ptrCast(@alignCast(context));
    try thread_items.setExpansion(gui, request);
}
