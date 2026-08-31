//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints; `redraw` collects whether the handled input needs a
//! frame.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const input_capability = @import("../input/root.zig");
const notifications = @import("../notifications/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const lua_config = @import("../config/root.zig");
const client_actions = @import("actions.zig");
const host_capabilities = @import("host_capabilities.zig");
const pane_inputs = @import("pane_inputs.zig");
const pane_viewports = @import("pane_viewports.zig");
const plugin_actions = @import("plugin_actions.zig");
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const notification_flow = @import("notifications.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");
const view_mod = @import("view.zig");
const action_mod = input_capability.action;
const input_mod = input_capability.host;
const keybind = input_capability.keybind;
const mouse_protocol = input_capability.mouse_protocol;
const multiplexer = workspace_capability.multiplexer;
const term = presentation.screen;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const client_mod = @import("client.zig");
const Client = client_mod;
const Action = action_mod.Action;
const monotonic = client_mod.monotonic;
const presentableModel = client_mod.presentableModel;
const encodeSgrMouse = mouse_protocol.encodeSgr;
const mouseTracked = mouse_protocol.tracked;

const InputHandler = @This();

client: *Client,
redraw: bool = false,

/// The model host input should act on, or null while no tab exists —
/// before bootstrap completes, or while the workspace-handoff model is
/// explicitly empty. Input arriving in that window is dropped, mirroring
/// `presentableModel` on the normal draw path.
fn activeModel(handler: *InputHandler) ?*multiplexer.Model {
    return presentableModel(&handler.client.model.workspace);
}

pub fn capturesKeys(handler: *const InputHandler) bool {
    return handler.client.model.name_prompt.active() or handler.client.view.hasAttachmentModal();
}

fn focusSidebarAgent(handler: *InputHandler, agent_key: agents.AgentKey) !bool {
    const plan = handler.client.model.planAgentNavigation(agent_key) orelse return false;
    switch (plan) {
        .local => |local| {
            if (local.select_tab) |tab_id| {
                try client_actions.selectTab(handler.client, .{ .tab_id = tab_id });
            }

            try client_actions.focusPane(handler.client, .{ .pane_id = local.pane_id });
            return false;
        },
        .handoff => |handoff| {
            if (handler.client.requests.count != 0) {
                return false;
            }

            _ = try workspace_handoffs.requestPane(
                handler.client,
                handoff.pane_id,
                handoff.fallback_workspace,
            );
            return true;
        },
    }
}

fn applyNotificationIntent(handler: *InputHandler, intent: view_mod.NotificationIntent, now_ns: u64) !void {
    switch (intent) {
        .activate => |id| {
            const activation = try notification_flow.activate(handler.client, id, now_ns) orelse return;

            try handler.followNotificationTarget(activation.target);
        },
        .dismiss => |id| _ = try notification_flow.dismiss(handler.client, id, now_ns),
    }
}

fn followNotificationTarget(handler: *InputHandler, target: notifications.Target) !void {
    switch (target) {
        .none => {},
        .select_tab => |tab_id| try client_actions.selectTab(handler.client, .{ .tab_id = tab_id }),
        .select_workspace => |workspace| try client_actions.switchWorkspace(handler.client, workspace),
        .focus_pane => |pane_id| try client_actions.focusPane(handler.client, .{ .pane_id = pane_id }),
    }
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
        if (handler.client.focusedAttachmentTarget()) |target| {
            handler.client.scheduleAttachmentCapture(target) catch {};
        }
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
    if (handler.client.view.hasAttachmentModal()) return;
    if (handler.client.model.name_prompt.active()) {
        _ = try name_prompts.handleInput(handler.client, "\x1b[200~");
        return;
    }
    if (handler.client.model.copyModeActive()) {
        return;
    }

    handler.client.paste_pane = try pane_inputs.beginPaste(handler.client) orelse return;
}

pub fn pasteContent(handler: *InputHandler, text: []const u8) !void {
    if (handler.client.view.hasAttachmentModal()) return;
    if (handler.client.model.name_prompt.active()) {
        _ = try name_prompts.handleInput(handler.client, text);
        return;
    }
    if (handler.client.model.copyModeActive()) {
        return;
    }

    const pane_id = handler.client.paste_pane orelse return;
    _ = try pane_inputs.continuePaste(handler.client, pane_id, text);
}

pub fn pasteEnd(handler: *InputHandler) !void {
    if (handler.client.view.hasAttachmentModal()) return;
    if (handler.client.model.name_prompt.active()) {
        _ = try name_prompts.handleInput(handler.client, "\x1b[201~");
        return;
    }
    if (handler.client.model.copyModeActive()) {
        return;
    }

    const pane_id = handler.client.paste_pane orelse return;
    handler.client.paste_pane = null;
    _ = try pane_inputs.endPaste(handler.client, pane_id);
}

pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
    if (comptime diagnostics.enabled) handler.client.metrics.mouse_events += 1;
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
    if (interaction.toggle_sidebar) {
        _ = try client_actions.apply(handler.client, .toggle_sidebar);
    }
    if (interaction.toggle_workspace_list) {
        _ = try client_actions.apply(handler.client, .toggle_workspace_list);
    }
    const agent_handoff = if (interaction.focus_agent) |agent_key|
        try handler.focusSidebarAgent(agent_key)
    else
        false;
    if (interaction.select_tab) |tab_id| {
        try client_actions.selectTab(handler.client, .{ .tab_id = tab_id });
    }
    if (interaction.focus_pane) |pane_id| {
        try client_actions.focusPane(handler.client, .{ .pane_id = pane_id });
    }
    if (interaction.rename_tab) |tab_id| {
        _ = name_prompts.beginTabRename(handler.client, tab_id);
    }
    if (interaction.select_workspace) |workspace| {
        try client_actions.switchWorkspace(handler.client, workspace);
    }
    if (interaction.notification) |intent| {
        try handler.applyNotificationIntent(intent, monotonic(handler.client.io));
    }
    if (interaction.layout_changed) {
        handler.client.graphics_store.invalidatePlacements();
        try handler.client.resizeAttached(model, handler.client.view.workbench());
    }
    handler.redraw = handler.redraw or interaction.redraw;
    if (interaction.consumed or agent_handoff or interaction.select_tab != null or
        interaction.focus_agent != null or
        !handler.client.view.workbench().contains(cell_event.x, cell_event.y)) return;
    const wheel_delta: ?i32 = switch (cell_event.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => null,
    };
    var pane = model.focusedPane() orelse return;
    if (wheel_delta != null) {
        for (model.layoutSnapshot(handler.client.view.workbench()).views()) |candidate| {
            if (!candidate.content.contains(cell_event.x, cell_event.y)) continue;
            pane = model.find(candidate.pane_id) orelse return;
            break;
        }
    }
    const pane_view = model.viewForPane(pane.id, handler.client.view.workbench()) orelse return;
    if (!pane_view.content.contains(cell_event.x, cell_event.y)) return;
    if (wheel_delta) |delta| {
        if (!pane.mouse.sgr or !mouseTracked(pane.mouse.tracking, cell_event.kind)) {
            if (pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll and
                pane.scroll.atBottom(pane.buffer.h))
            {
                const bytes = if (delta < 0) "\x1b[A" else "\x1b[B";
                for (0..@abs(delta)) |_| {
                    _ = try pane_inputs.send(handler.client, .{
                        .target = .{ .pane = pane.id },
                        .source = .mouse,
                        .payload = .{ .bytes = bytes },
                    });
                }
            } else {
                var viewport = pane_viewports.handler(handler.client);
                _ = try viewport.execute(.{
                    .pane_id = pane.id,
                    .target = .{ .relative = delta },
                });
            }
            return;
        }
    }
    if (!pane.mouse.sgr or !mouseTracked(pane.mouse.tracking, cell_event.kind)) return;
    var encoded: [64]u8 = undefined;
    const exact_x: ?u32 = if (pane.mouse.pixels and exterior_pixels)
        event.raw_x - @as(u32, pane_view.content.x) * host_size.cell_width_px
    else
        null;
    const exact_y: ?u32 = if (pane.mouse.pixels and exterior_pixels)
        event.raw_y - @as(u32, pane_view.content.y) * host_size.cell_height_px
    else
        null;
    const bytes = try encodeSgrMouse(
        &encoded,
        cell_event,
        cell_event.x - pane_view.content.x,
        cell_event.y - pane_view.content.y,
        pane.mouse.pixels,
        host_size.cell_width_px,
        host_size.cell_height_px,
        exact_x,
        exact_y,
    );
    _ = try pane_inputs.send(handler.client, .{
        .target = .{ .pane = pane.id },
        .source = .mouse,
        .payload = .{ .bytes = bytes },
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
    if (handler.client.model.name_prompt.active()) return .continue_routing;
    switch (value) {
        .lua_callback => |reference| {
            const generation = handler.client.lua_generation orelse
                return .continue_routing;
            const batch = generation.invokeCallback(
                reference,
                handler.callbackContext(),
                &handler.client.config_diagnostic,
            ) catch {
                handler.redraw = true;
                return .continue_routing;
            };
            for (batch.slice()) |effect| switch (effect) {
                .plugin => |requested| {
                    const registry = handler.client.plugin_registry orelse {
                        handler.client.config_diagnostic.set(
                            "Lua callback referenced a plugin but no registry is active",
                            .{},
                        );
                        handler.redraw = true;
                        return .continue_routing;
                    };
                    _ = registry.resolve(requested) catch |err| {
                        handler.client.config_diagnostic.set(
                            "Lua callback returned an invalid plugin action: {s}",
                            .{@errorName(err)},
                        );
                        handler.redraw = true;
                        return .continue_routing;
                    };
                },
                else => {},
            };
            handler.client.config_diagnostic.len = 0;
            for (batch.slice()) |effect|
                if (try handler.action(effect) == .stop) return .stop;
            return .continue_routing;
        },
        .lua_expr => |reference| {
            const generation = handler.client.lua_generation orelse
                return .continue_routing;
            const decision = generation.invokeExpression(
                reference,
                handler.callbackContext(),
                &handler.client.config_diagnostic,
            ) catch {
                handler.redraw = true;
                return .continue_routing;
            };
            handler.client.config_diagnostic.len = 0;
            switch (decision) {
                .consume => {},
                .forward_binding => |keys| for (keys.slice()) |key_value|
                    try handler.key(key_value),
                .keys => |keys| for (keys.slice()) |key_value|
                    try handler.key(key_value),
                .paste => |paste| try handler.sendPaste(paste.slice()),
            }
            return .continue_routing;
        },
        .plugin => |requested| {
            _ = try plugin_actions.start(
                handler.client,
                requested,
                handler.callbackContext(),
            );
            return .continue_routing;
        },
        else => return client_actions.apply(handler.client, value),
    }
}

fn callbackContext(handler: *InputHandler) lua_config.CallbackContext {
    const model = handler.activeModel() orelse return .{
        .sidebar_visible = handler.client.model.sidebarVisible(),
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    };
    const focused = model.focusedPane();
    return .{
        .sidebar_visible = handler.client.model.sidebarVisible(),
        .tab_count = @intCast(handler.client.model.workspace.count),
        .active_tab_index = @intCast(handler.client.model.workspace.activeIndex() orelse 0),
        .pane_count = @intCast(model.pane_count),
        .focused_pane_id = if (focused) |pane| schema.id.raw(pane.id) else 0,
    };
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
