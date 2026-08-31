//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints.

const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const action_routing = @import("action_routing.zig");
const host_capabilities = @import("host_capabilities.zig");
const key_routing = @import("key_routing.zig");
const paste_routing = @import("paste_routing.zig");
const pointer_routing = @import("pointer_routing.zig");
const action_mod = input_capability.action;
const keybind = input_capability.keybind;
const term = presentation.screen;

const Client = @import("client.zig");
const Action = action_mod.Action;

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
pub fn key(handler: *InputHandler, value: keybind.Key) !void {
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

/// Reconciles one host-terminal capability response without forwarding it.
///
/// ```zig
/// try handler.terminalResponse(response);
/// ```
pub fn terminalResponse(handler: *InputHandler, response: term.Event.TerminalResponse) !void {
    _ = try host_capabilities.observe(handler.client, response);
}

pub fn action(handler: *InputHandler, value: Action) !keybind.Control {
    return action_routing.apply(handler.client, value);
}
