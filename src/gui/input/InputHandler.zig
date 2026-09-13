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

/// Example: `const control = try handler.action(.new_tab);`
pub fn action(handler: *Handler, value: client.Action) !client.Control {
    return client.controllers.action_routing.apply(handler.app, value);
}

/// Example: `const policy = handler.repeatPolicy(action);`
pub fn repeatPolicy(handler: *const Handler, value: client.Action) ?client.RepeatPolicy {
    return client.controllers.action_routing.repeatPolicy(handler.app, value);
}
