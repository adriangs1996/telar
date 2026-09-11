//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints.

const Client = @import("../Client.zig");
const key_routing = @import("../controllers/input/key_routing.zig");
const KeyType = @import("telar-client").Key;
const paste_routing = @import("../controllers/input/paste_routing.zig");
const term = @import("../../presentation/screen_support.zig");
const pointer_routing = @import("../controllers/input/pointer_routing.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const runtime_transport = @import("../entrypoints/runtime_io.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const Action = @import("telar-client").Action;
const RepeatPolicyType = @import("telar-client").RepeatPolicy;
const action_routing = @import("../controllers/input/action_routing.zig");
const ControlType = @import("telar-client").Control;

const InputHandler = @This();

client: *Client,

/// Returns whether the current modal or prompt must bypass configured keys.
///
/// ```zig
/// if (handler.capturesKeys()) routeDirectly();
/// ```
pub fn capturesKeys(handler: *const InputHandler) bool {
    return key_routing.captures(handler.client);
}

/// Routes one borrowed byte slice after the native router has replayed it.
///
/// ```zig
/// try handler.forward(bytes);
/// ```
pub fn forward(handler: *InputHandler, bytes: []const u8) !void {
    _ = try key_routing.apply(handler.client, .{ .bytes = bytes });
}

/// Routes one semantic host key after native binding resolution.
///
/// ```zig
/// try handler.key(pressed);
/// ```
pub fn key(handler: *InputHandler, value: KeyType) !void {
    _ = try key_routing.apply(handler.client, .{ .key = value });
}

pub fn pasteStart(handler: *InputHandler) !void {
    _ = try paste_routing.start(handler.client);
}

pub fn pasteContent(handler: *InputHandler, text: []const u8) !void {
    _ = try paste_routing.content(handler.client, text);
}

pub fn pasteEnd(handler: *InputHandler) !void {
    _ = try paste_routing.finish(handler.client);
}

pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
    _ = try pointer_routing.apply(handler.client, event);
}

/// Reconciles one host-terminal response without forwarding it: capability
/// probe replies update the host model, and Kitty replies for pane images
/// tell the graphics store whether the host took a shared object.
///
/// ```zig
/// try handler.terminalResponse(response);
/// ```
pub fn terminalResponse(handler: *InputHandler, response: term.Event.TerminalResponse) !void {
    _ = try host_capabilities.observe(handler.client, response);
    switch (response) {
        .kitty_graphics => |reply| {
            if (!kitty_delivery.noteHostReply(&handler.client.graphics_store, reply.image_id, reply.supported)) {
                return;
            }
            try runtime_transport.flushGraphicsCredits(handler.client);
            try presentation_lifecycle.observe(handler.client);
        },
        else => {},
    }
}

/// Opts native scroll bindings into paced repeats for their current pane.
/// For example: `const policy = handler.repeatPolicy(action);`.
pub fn repeatPolicy(handler: *const InputHandler, value: Action) ?RepeatPolicyType {
    return action_routing.repeatPolicy(handler.client, value);
}

pub fn action(handler: *InputHandler, value: Action) !ControlType {
    return action_routing.apply(handler.client, value);
}
