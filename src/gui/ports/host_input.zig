const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const NativeInput = @import("../NativeInput.zig");

/// Example: `app.host_input_source = host_input.port(app);`
pub fn port(app: *client.AttachedClient) client.HostInputSource {
    return .{ .context = app, .resume_read_fn = resumeRead, .route_prompt_bytes_fn = promptBytes, .adopt_bindings_fn = adopt };
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
