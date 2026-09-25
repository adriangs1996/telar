const client = @import("telar-client");
const GuiAdapter = @import("../GuiAdapter.zig");

/// Example: `gui.app.host_input_source = host_input.port(gui);`
pub fn port(gui: *GuiAdapter) client.HostInputSource {
    return .{
        .context = gui,
        .route_prompt_bytes_fn = promptBytes,
    };
}

fn promptBytes(context: *anyopaque, bytes: []const u8) !void {
    const gui: *GuiAdapter = @ptrCast(@alignCast(context));
    const app = &gui.app;
    _ = try client.name_prompt.inputPrompt(
        app,
        .{
            .paste_text = bytes,
        },
    );
}
