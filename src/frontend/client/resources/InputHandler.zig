//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const Client = @import("telar-client").AttachedClient;
const key_routing = @import("telar-client").controllers.key_routing;
const KeyType = @import("telar-client").Key;
const paste_routing = @import("telar-client").controllers.paste_routing;
const term = @import("../../presentation/screen_support.zig");
const MouseType = @import("telar-client").Mouse;
const pointer_routing = @import("telar-client").controllers.pointer_routing;
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const runtime_transport = @import("telar-client").runtime_io;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const Action = @import("telar-client").Action;
const RepeatPolicyType = @import("telar-client").RepeatPolicy;
const action_routing = @import("telar-client").controllers.action_routing;
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

pub fn mouse(handler: *InputHandler, event: MouseType) !void {
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
            if (!kitty_delivery.noteHostReply(&host(handler.client).graphics_store, reply.image_id, reply.supported)) {
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
