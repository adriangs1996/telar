//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints; `redraw` collects whether the handled input needs a
//! frame.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const action_routing = @import("action_routing.zig");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const host_capabilities = @import("host_capabilities.zig");
const key_routing = @import("key_routing.zig");
const pane_mouse_inputs = @import("pane_mouse_inputs.zig");
const paste_routing = @import("paste_routing.zig");
const view_interactions = @import("view_interactions.zig");
const action_mod = input_capability.action;
const keybind = input_capability.keybind;
const multiplexer = workspace_capability.multiplexer;
const term = presentation.screen;

const Io = std.Io;
const diagnostics = core.diagnostics;

const Client = @import("client.zig");
const Action = action_mod.Action;

const InputHandler = @This();

client: *Client,
redraw: bool = false,

/// The model host input should act on, or null while no tab exists —
/// before bootstrap completes, or while the workspace-handoff model is
/// explicitly empty. Input arriving in that window is dropped.
fn activeModel(handler: *InputHandler) ?*multiplexer.Model {
    return handler.client.model.activeTabModel();
}

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
    const outcome = try key_routing.apply(handler.client, .{ .key = value });
    handler.redraw = handler.redraw or outcome.redraw;
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
    if (comptime diagnostics.enabled) {
        handler.client.telemetry.metrics.mouse_events += 1;
    }

    if (handler.client.model.name_prompt.active()) {
        return;
    }

    const capabilities = handler.client.model.hostCapabilities();
    const host_size = handler.client.model.hostSize();
    const exterior_pixels = capabilities.mouse_pixels == .supported and
        host_size.cell_width_px != 0 and host_size.cell_height_px != 0;
    var cell_event = event;
    if (exterior_pixels) {
        cell_event.x = std.math.cast(u16, event.raw_x / host_size.cell_width_px) orelse
            std.math.maxInt(u16);
        cell_event.y = std.math.cast(u16, event.raw_y / host_size.cell_height_px) orelse
            std.math.maxInt(u16);
    }

    const model = handler.activeModel() orelse return;

    if (try copy_mode_pointer.apply(handler.client, model, cell_event)) {
        return;
    }

    const interaction = handler.client.view.handleMouse(cell_event);
    const interaction_outcome = try view_interactions.apply(handler.client, model, interaction);
    handler.redraw = handler.redraw or interaction_outcome.redraw;
    if (interaction_outcome.consume_pane_input or
        !handler.client.view.workbench().contains(cell_event.x, cell_event.y))
    {
        return;
    }

    _ = try pane_mouse_inputs.apply(handler.client, model, .{
        .event = cell_event,
        .exterior_pixels = exterior_pixels,
        .cell_width_px = host_size.cell_width_px,
        .cell_height_px = host_size.cell_height_px,
    });
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
    return action_routing.apply(handler.client, value, &handler.redraw);
}
