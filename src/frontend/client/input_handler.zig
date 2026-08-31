//! Host input dispatch for one attached client. Constructed per event by the
//! client's entrypoints; `redraw` collects whether the handled input needs a
//! frame.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const lua_config = @import("../config/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const widgets = @import("../widgets/root.zig");
const pane_closures = @import("pane_closures.zig");
const pane_focus = @import("pane_focus.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_splits = @import("pane_splits.zig");
const pane_viewports = @import("pane_viewports.zig");
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const sidebar_toggles = @import("sidebar_toggles.zig");
const tab_attachments = @import("tab_attachments.zig");
const tab_closures = @import("tab_closures.zig");
const tab_creations = @import("tab_creations.zig");
const tab_moves = @import("tab_moves.zig");
const tab_selections = @import("tab_selections.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");
const workspace_list_toggles = @import("workspace_list_toggles.zig");
const action_mod = input_capability.action;
const input_mod = input_capability.host;
const keybind = input_capability.keybind;
const mouse_protocol = input_capability.mouse_protocol;
const layout_mod = workspace_capability.layout;
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

fn selectTab(handler: *InputHandler, target: tab_selections.Target) !void {
    var use_case = tab_selections.selectionHandler(handler.client);

    _ = try use_case.execute(.{ .target = target });
}

fn focusPane(handler: *InputHandler, target: pane_focus.Target) !void {
    var use_case = pane_focus.handler(handler.client);

    _ = try use_case.execute(.{
        .target = target,
        .area = handler.client.view.workbench(),
    });
}

/// Switching targets the runtime identity, not its path. Multiple explicit
/// workspaces may share one cwd and must remain independently selectable.
fn switchWorkspace(handler: *InputHandler, workspace: schema.WorkspaceId) !void {
    const client = handler.client;
    if (client.requests.count != 0) return;
    if (client.view.workspace_list.indexOf(workspace) == null) return;
    if (client.model.workspace.workspace) |current| switch (current) {
        .workspace => |id| if (id == workspace) return,
        .worktree => {},
    };
    try handler.switchWorkspaceResolved(workspace);
}

/// Starts a handoff chosen from runtime-owned workspace state. Unlike an
/// interactive selection, it must not consult the client's stale list.
pub fn switchWorkspaceResolved(handler: *InputHandler, workspace: schema.WorkspaceId) !void {
    _ = try workspace_handoffs.requestWorkspace(handler.client, workspace);
}

fn focusSidebarAgent(
    handler: *InputHandler,
    agent_key: widgets.sidebar.AgentKey,
) !bool {
    const agent = handler.client.view.sidebar_snapshot.find(agent_key) orelse return false;
    if (handler.client.model.workspace.tabForPane(agent_key.pane_id)) |tab| {
        if (handler.client.model.workspace.activeConst().?.location.tab_id != tab.location.tab_id) {
            try handler.selectTab(.{ .tab_id = tab.location.tab_id });
        }

        try handler.focusPane(.{ .pane_id = agent_key.pane_id });
        return false;
    }
    if (handler.client.requests.count != 0) return false;
    const fallback = switch (agent.location.workspace) {
        .workspace => |workspace| workspace,
        .worktree => null,
    };
    _ = try workspace_handoffs.requestPane(handler.client, agent_key.pane_id, fallback);
    return true;
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

    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    try handler.sendPaneBytes(pane, bytes);
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

    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    var encoded: [32]u8 = undefined;
    try handler.sendPaneBytes(
        pane,
        try input_mod.encodeKey(&encoded, value, pane.input_modes),
    );
    if (isClipboardImagePasteKey(value)) {
        if (handler.client.view.focusedAttachmentTarget(model)) |target|
            handler.client.scheduleAttachmentCapture(target) catch {};
    }
}

fn isClipboardImagePasteKey(value: keybind.Key) bool {
    return value.isCtrl('v') and !value.mods.alt and !value.mods.shift;
}

fn sendPaste(handler: *InputHandler, text: []const u8) !void {
    if (handler.client.model.copyModeActive()) {
        return;
    }

    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    var encoded: [lua_config.max_expression_paste_bytes + 16]u8 = undefined;
    try handler.sendPaneBytes(
        pane,
        try input_mod.encodePaste(&encoded, text, pane.input_modes),
    );
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

    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    handler.client.paste_pane = pane.id;
    if (pane.input_modes.bracketed_paste)
        try handler.sendPaneBytes(pane, "\x1b[200~");
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
    const pane = handler.client.model.workspace.findPane(pane_id) orelse return;
    if (pane.attached) try handler.sendPaneBytes(pane, text);
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
    const pane = handler.client.model.workspace.findPane(pane_id) orelse return;
    if (pane.attached and pane.input_modes.bracketed_paste)
        try handler.sendPaneBytes(pane, "\x1b[201~");
}

fn sendPaneBytes(handler: *InputHandler, pane: *multiplexer.Pane, bytes: []const u8) !void {
    const started = diagnostics.now(handler.client.io);
    var viewport = pane_viewports.handler(handler.client);
    _ = try viewport.execute(.{ .pane_id = pane.id, .target = .bottom });
    try handler.client.enqueueInput(pane.id, bytes);
    if (comptime diagnostics.enabled) {
        handler.client.metrics.input_events += 1;
        handler.client.metrics.input_bytes += bytes.len;
        handler.client.metrics.input_enqueue.observe(diagnostics.elapsed(started, diagnostics.now(handler.client.io)));
    }
}

pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
    if (comptime diagnostics.enabled) handler.client.metrics.mouse_events += 1;
    if (handler.client.model.name_prompt.active()) {
        return;
    }

    const cell_size = handler.client.capabilities.cellSize(
        handler.client.view.scratch.w,
        handler.client.view.scratch.h,
    );
    const exterior_pixels = handler.client.capabilities.mouse_pixels == .supported and
        cell_size.width != 0 and cell_size.height != 0;
    var cell_event = event;
    if (exterior_pixels) {
        cell_event.x = std.math.cast(u16, event.raw_x / cell_size.width) orelse
            std.math.maxInt(u16);
        cell_event.y = std.math.cast(u16, event.raw_y / cell_size.height) orelse
            std.math.maxInt(u16);
    }
    const model = handler.activeModel() orelse return;
    if (try handler.copyModeMouse(cell_event, model)) {
        return;
    }

    const interaction = handler.client.view.handleMouse(cell_event, monotonic(handler.client.io));
    if (interaction.toggle_sidebar) {
        try handler.toggleSidebar();
    }
    if (interaction.toggle_workspace_list) {
        handler.toggleWorkspaceList();
    }
    const agent_handoff = if (interaction.focus_agent) |agent_key|
        try handler.focusSidebarAgent(agent_key)
    else
        false;
    if (interaction.select_tab) |tab_id| {
        try handler.selectTab(.{ .tab_id = tab_id });
    }
    if (interaction.focus_pane) |pane_id| {
        try handler.focusPane(.{ .pane_id = pane_id });
    }
    if (interaction.rename_tab) |tab_id| {
        _ = name_prompts.beginTabRename(handler.client, tab_id);
    }
    if (interaction.select_workspace) |workspace| try handler.switchWorkspace(workspace);
    if (interaction.notification_target) |target| switch (target) {
        .none => {},
        .select_tab => |tab_id| try handler.selectTab(.{ .tab_id = tab_id }),
        .select_workspace => |workspace| try handler.switchWorkspace(workspace),
        .focus_pane => |pane_id| try handler.focusPane(.{ .pane_id = pane_id }),
    };
    if (interaction.notification_target != null)
        try handler.client.scheduleNotificationTick();
    if (interaction.layout_changed) {
        handler.client.graphics_store.invalidatePlacements();
        try handler.client.resizeAttached(model, handler.client.view.workbench());
    }
    handler.redraw = handler.redraw or interaction.redraw;
    if (interaction.consumed or agent_handoff or interaction.select_tab != null or
        interaction.focus_agent != null or
        interaction.notification_target != null or
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
                for (0..@abs(delta)) |_| try handler.client.enqueueInput(pane.id, bytes);
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
        event.raw_x - @as(u32, pane_view.content.x) * cell_size.width
    else
        null;
    const exact_y: ?u32 = if (pane.mouse.pixels and exterior_pixels)
        event.raw_y - @as(u32, pane_view.content.y) * cell_size.height
    else
        null;
    const bytes = try encodeSgrMouse(
        &encoded,
        cell_event,
        cell_event.x - pane_view.content.x,
        cell_event.y - pane_view.content.y,
        pane.mouse.pixels,
        cell_size.width,
        cell_size.height,
        exact_x,
        exact_y,
    );
    try handler.client.enqueueInput(pane.id, bytes);
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

pub fn terminalResponse(handler: *InputHandler, response: term.Event.TerminalResponse) !void {
    if (!handler.client.capabilities.observe(response)) return;
    const cell_size = handler.client.capabilities.cellSize(
        handler.client.view.scratch.w,
        handler.client.view.scratch.h,
    );
    var tabs = handler.client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        tab.model.setCellSize(cell_size.width, cell_size.height);
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            tab.model.setGraphicsPlaceholder(pane.id, handler.client.capabilities.kitty_graphics != .supported and
                handler.client.graphics_store.hasPaneGraphics(pane.id));
        }
    }
    handler.client.graphics_store.invalidatePlacements();
    try handler.client.view.configureSidebar(
        handler.client.sidebar_rendering,
        handler.client.capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    if (handler.client.model.workspace.active()) |active|
        try handler.client.resizeAttached(&active.model, handler.client.view.workbench());
    handler.client.view.invalidate();
    handler.redraw = true;
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
            if (handler.client.plugin_pending) return .continue_routing;
            const registry = handler.client.plugin_registry orelse
                return .continue_routing;
            const invocation = registry.resolve(requested) catch |err| {
                handler.client.config_diagnostic.set(
                    "plugin action cannot be resolved: {s}",
                    .{@errorName(err)},
                );
                handler.redraw = true;
                return .continue_routing;
            };
            const request = try registry.workerRequest(
                invocation,
                handler.callbackContext(),
            );
            try handler.client.schedulePluginAction(request);
            return .continue_routing;
        },
        else => return handler.applyNativeAction(value),
    }
}

pub fn applyNativeAction(handler: *InputHandler, value: Action) !keybind.Control {
    switch (value) {
        .enter_copy_mode => {},
        else => {
            if (handler.client.model.copyModeActive()) {
                _ = try copy_modes.leave(handler.client);
            }
        },
    }
    switch (value) {
        .split_pane => |direction| try handler.beginSplit(switch (direction) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        }),
        .focus_pane => |direction| try handler.focusPane(.{ .direction = switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        } }),
        .resize_pane => |direction| try handler.resizePane(switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }),
        .toggle_pane_fullscreen => try handler.togglePaneFullscreen(),
        .toggle_sidebar => try handler.toggleSidebar(),
        .toggle_workspace_list => handler.toggleWorkspaceList(),
        .new_workspace => _ = name_prompts.beginWorkspaceCreate(handler.client),
        .rename_workspace => _ = name_prompts.beginWorkspaceRename(handler.client),
        .select_workspace => |position| try handler.selectWorkspacePosition(position),
        .close_pane => try handler.closeFocused(),
        .new_tab => try handler.createTab(),
        .select_tab_offset => |offset| try handler.selectTab(.{ .offset = offset }),
        .select_tab => |position| try handler.selectTab(.{ .position = position }),
        .rename_tab => _ = name_prompts.beginActiveTabRename(handler.client),
        .close_tab => try handler.closeTab(),
        .move_tab => |direction| try handler.moveTab(switch (direction) {
            .previous => .previous,
            .next => .next,
        }),
        .detach => {
            var tabs = handler.client.model.workspace.tabIterator();
            while (tabs.next()) |tab| try tab_attachments.detach(handler.client, tab);
            return .stop;
        },
        .enter_copy_mode => _ = copy_modes.enter(handler.client),
        .notification => |*notification| {
            const request_id = try handler.client.nextId();
            try handler.client.enqueueNotificationRequest(.{
                .request_id = request_id,
                .notification = .{
                    .level = notification.level,
                    .duration_ms = notification.duration_ms,
                    .target = notification.target,
                    .title = notification.title(),
                    .message = notification.message(),
                },
            });
        },
        .lua_callback, .lua_expr, .plugin => unreachable,
    }
    return .continue_routing;
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

fn beginSplit(handler: *InputHandler, axis: layout_mod.Axis) !void {
    var use_case = pane_splits.requestHandler(handler.client);
    _ = try use_case.execute(.{
        .axis = axis,
        .area = handler.client.view.workbench(),
    });
}

fn resizePane(handler: *InputHandler, direction: layout_mod.Direction) !void {
    var use_case = pane_geometry.resizeHandler(handler.client);

    _ = try use_case.execute(.{
        .direction = direction,
        .area = handler.client.view.workbench(),
    });
}

fn togglePaneFullscreen(handler: *InputHandler) !void {
    var use_case = pane_geometry.fullscreenHandler(handler.client);

    _ = try use_case.execute(.{ .area = handler.client.view.workbench() });
}

fn toggleSidebar(handler: *InputHandler) !void {
    var use_case = sidebar_toggles.handler(handler.client);

    _ = try use_case.execute();
}

fn toggleWorkspaceList(handler: *InputHandler) void {
    var use_case = workspace_list_toggles.handler(handler.client);

    _ = use_case.execute();
}

fn closeFocused(handler: *InputHandler) !void {
    var use_case = pane_closures.requestHandler(handler.client);
    _ = try use_case.execute();
}

fn createTab(handler: *InputHandler) !void {
    var use_case = tab_creations.requestHandler(handler.client);
    _ = try use_case.execute(.{});
}

fn selectWorkspacePosition(handler: *InputHandler, position: usize) !void {
    const workspaces = &handler.client.view.workspace_list;
    const workspace = workspaces.workspaceAtPosition(position) orelse return;
    try handler.switchWorkspace(workspace);
}

fn closeTab(handler: *InputHandler) !void {
    var use_case = tab_closures.requestHandler(handler.client);

    _ = try use_case.execute();
}

fn moveTab(handler: *InputHandler, direction: schema.TabMoveDirection) !void {
    var use_case = tab_moves.requestHandler(handler.client);
    _ = try use_case.execute(.{ .direction = direction });
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
