const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const thread_items = @import("../widgets/interaction/thread_items.zig");
const NativeInput = @import("../NativeInput.zig");

/// Example: `app.host_input_source = host_input.port(app);`
pub fn port(app: *client.AttachedClient) client.HostInputSource {
    return .{ .context = app, .resume_read_fn = resumeRead, .route_prompt_bytes_fn = promptBytes, .adopt_bindings_fn = adopt, .enter_thread_copy_mode_fn = enterCopy, .thread_copy_mode_active_fn = copyActive, .leave_thread_copy_mode_fn = leaveCopy, .set_thread_expansion_fn = setExpansion };
}

fn resumeRead(context: *anyopaque) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).resumeInput();
}

fn promptBytes(context: *anyopaque, bytes: []const u8) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try NativeInput.routePromptBytes(app, bytes);
}

fn adopt(context: *anyopaque, config: client.RouterConfig) void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    GuiClient.of(app).input.adopt(app, config);
}

fn enterCopy(context: *anyopaque, pane_id: @import("telar-core").PaneId) bool {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    return @import("../widgets/interaction/thread_selection.zig").enter(GuiClient.of(app), pane_id);
}

fn copyActive(context: *anyopaque) bool {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    return @import("../widgets/interaction/thread_selection.zig").active(GuiClient.of(app));
}

fn leaveCopy(context: *anyopaque) bool {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    return @import("../widgets/interaction/thread_selection.zig").leave(GuiClient.of(app));
}

fn setExpansion(context: *anyopaque, request: client.ThreadExpansion) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try thread_items.setExpansion(GuiClient.of(app), request);
}
