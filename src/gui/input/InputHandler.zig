//! Native semantic events enter the same client policies as the terminal host.
const client = @import("telar-client");
const Handler = @This();

app: *client.AttachedClient,

/// Example: `if (handler.capturesKeys()) routeToPrompt();`
pub fn capturesKeys(handler: *const Handler) bool {
    return client.controllers.key_routing.captures(handler.app);
}

/// Example: `try handler.forward(bytes);`
pub fn forward(handler: *Handler, bytes: []const u8) !void {
    _ = try client.controllers.key_routing.apply(handler.app, .{ .bytes = bytes });
}

/// Example: `try handler.key(key);`
pub fn key(handler: *Handler, value: client.Key) !void {
    _ = try client.controllers.key_routing.apply(handler.app, .{ .key = value });
}

/// The goto and suggest keys open the native palette already prefixed;
/// every other action keeps the shared routing. Copy mode retires first,
/// as the shared native action policy does.
/// Example: `const control = try handler.action(.new_tab);`
pub fn action(handler: *Handler, value: client.Action) !client.Control {
    const prefix: client.command_palette.Prefix = switch (value) {
        .goto_picker => .goto,
        .suggest_command => .suggest,
        else => return client.controllers.action_routing.apply(handler.app, value),
    };
    if (handler.app.model.copyModeActive()) {
        _ = try client.controllers.copy_modes.leave(handler.app);
    }

    _ = client.controllers.name_prompts.beginPalette(handler.app, prefix);
    return .continue_routing;
}

/// Example: `const policy = handler.repeatPolicy(action);`
pub fn repeatPolicy(handler: *const Handler, value: client.Action) ?client.RepeatPolicy {
    return client.controllers.action_routing.repeatPolicy(handler.app, value);
}

/// Ends native control capture after ordered overflow or focus cancellation.
/// Example: `handler.cancelPointer();`.
pub fn cancelPointer(handler: *Handler) void {
    const gui = @import("../GuiClient.zig").of(handler.app);
    gui.chrome.cancelPointer();
    gui.overlays.cancelPointer();
}
