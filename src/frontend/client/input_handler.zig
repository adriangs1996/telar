//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints; `redraw` collects whether the handled input needs a
//! frame.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const client_actions = @import("actions.zig");
const clipboard_images = @import("clipboard_images.zig");
const host_capabilities = @import("host_capabilities.zig");
const lua_actions = @import("lua_actions.zig");
const pane_inputs = @import("pane_inputs.zig");
const pane_mouse_inputs = @import("pane_mouse_inputs.zig");
const paste_routing = @import("paste_routing.zig");
const plugin_actions = @import("plugin_actions.zig");
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const view_interactions = @import("view_interactions.zig");
const action_mod = input_capability.action;
const input_mod = input_capability.host;
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

pub fn capturesKeys(handler: *const InputHandler) bool {
    return handler.client.model.name_prompt.active() or handler.client.view.hasAttachmentModal();
}

pub fn forward(handler: *InputHandler, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (handler.client.model.name_prompt.active()) {
        _ = try name_prompts.handleInput(handler.client, bytes);
        return;
    }
    if (handler.client.model.copyModeActive()) {
        return;
    }

    _ = try pane_inputs.send(handler.client, .{
        .target = .focused,
        .source = .host,
        .payload = .{ .bytes = bytes },
    });
}

pub fn key(handler: *InputHandler, value: keybind.Key) !void {
    if (handler.client.view.hasAttachmentModal()) {
        if (value.code == .escape) _ = handler.client.view.closeAttachmentModal();
        handler.redraw = true;
        return;
    }
    if (handler.client.model.name_prompt.active()) {
        var editing_bytes: [32]u8 = undefined;
        _ = try name_prompts.handleInput(
            handler.client,
            try input_mod.encodeKey(&editing_bytes, value, .{}),
        );
        return;
    }
    if (handler.client.model.copyModeActive()) {
        _ = try copy_modes.key(handler.client, value);
        return;
    }

    _ = try pane_inputs.send(handler.client, .{
        .target = .focused,
        .source = .host,
        .payload = .{ .key = value },
    }) orelse return;
    if (isClipboardImagePasteKey(value)) {
        _ = clipboard_images.start(handler.client) catch {};
    }
}

fn isClipboardImagePasteKey(value: keybind.Key) bool {
    return value.isCtrl('v') and !value.mods.alt and !value.mods.shift;
}

fn sendPaste(handler: *InputHandler, text: []const u8) !void {
    if (handler.client.model.copyModeActive()) {
        return;
    }

    _ = try pane_inputs.expressionPaste(handler.client, text);
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
    if (try handler.copyModeMouse(cell_event, model)) {
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

fn copyModeMouse(handler: *InputHandler, event: term.Event.Mouse, model: *multiplexer.Model) !bool {
    if (!handler.client.model.copyModeActive()) {
        return false;
    }

    const delta: i32 = switch (event.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => return true,
    };
    const projection = handler.client.model.copyModeProjection() orelse return true;
    const pane = model.find(projection.pane_id) orelse {
        _ = try copy_modes.leave(handler.client);
        return true;
    };
    const pane_view = model.viewForPane(pane.id, handler.client.view.workbench()) orelse return true;
    if (!pane_view.content.contains(event.x, event.y)) {
        return true;
    }

    _ = try copy_modes.vertical(handler.client, delta);
    return true;
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
    if (handler.client.model.name_prompt.active()) {
        return .continue_routing;
    }

    switch (value) {
        .lua_callback => |reference| return handler.applyLuaAction(.{ .callback = reference }),
        .lua_expr => |reference| return handler.applyLuaAction(.{ .expression = reference }),
        .plugin => |requested| {
            _ = try plugin_actions.start(
                handler.client,
                requested,
                handler.client.model.callbackContext(),
            );
            return .continue_routing;
        },
        else => return client_actions.apply(handler.client, value),
    }
}

fn applyLuaAction(handler: *InputHandler, command: lua_actions.Command) !keybind.Control {
    const outcome = try lua_actions.execute(handler.client, command);
    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key_value| {
                try handler.key(key_value);
            },
            .paste => |paste| try handler.sendPaste(paste.slice()),
        },
    }

    return .continue_routing;
}

test "only an unmodified control-v triggers local image inspection" {
    const control_v = try keybind.parseKey("ctrl+v");
    try std.testing.expect(isClipboardImagePasteKey(control_v));
    var shifted = control_v;
    shifted.mods.shift = true;
    try std.testing.expect(!isClipboardImagePasteKey(shifted));
    try std.testing.expect(!isClipboardImagePasteKey(try keybind.parseKey("ctrl+shift+left")));
    try std.testing.expect(!isClipboardImagePasteKey(try keybind.parseKey("alt+v")));
    try std.testing.expect(!isClipboardImagePasteKey(try keybind.parseKey("v")));
}
