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
const tab_attachments = @import("tab_attachments.zig");
const action_mod = input_capability.action;
const copy_mode = input_capability.copy_mode;
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
const rectSize = multiplexer.rectSize;
const encodeSgrMouse = mouse_protocol.encodeSgr;
const mouseTracked = mouse_protocol.tracked;

const InputHandler = @This();

client: *Client,
redraw: bool = false,

/// The model host input should act on, or null while no tab exists —
/// before bootstrap completes, or during a workspace handoff after
/// `tabs.deinit()` while the runtime's reply is outstanding. Input
/// arriving in that window is dropped, mirroring presentableModel on
/// the draw path.
fn activeModel(handler: *InputHandler) ?*multiplexer.Model {
    return presentableModel(&handler.client.model.workspace);
}

pub fn capturesKeys(handler: *const InputHandler) bool {
    return handler.client.mode == .prompt or handler.client.view.hasAttachmentModal();
}

fn selectTab(handler: *InputHandler, tab_id: schema.TabId) !void {
    var use_case = tab_attachments.selectionHandler(handler.client);

    _ = try use_case.execute(.{ .tab_id = tab_id });
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
    const client = handler.client;
    if (client.requests.count != 0) return error.WorkspaceSwitchWhileRequestPending;
    const destination: schema.WorkspaceLocation = .{ .workspace = workspace };
    const target: schema.PaneTarget = if (client.navigation_history.find(destination)) |bookmark|
        .{ .pane = bookmark.pane_id }
    else
        .{ .workspace = workspace };
    try handler.beginWorkspaceHandoff(target, workspace);
}

fn beginWorkspaceHandoff(
    handler: *InputHandler,
    target: schema.PaneTarget,
    fallback_workspace: ?schema.WorkspaceId,
) !void {
    const client = handler.client;
    client.rememberCurrentNavigation();
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| try tab_attachments.detach(client, tab);
    client.model.workspace.deinit();
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .initial_open = .{ .fallback_workspace = fallback_workspace } },
        .{ .open_pane = .{
            .request_id = request_id,
            .target = target,
            .size = rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
            .launch = null,
        } },
    );
    client.view.invalidate();
    handler.redraw = true;
}

fn focusSidebarAgent(
    handler: *InputHandler,
    agent_key: widgets.sidebar.AgentKey,
) !bool {
    const agent = handler.client.view.sidebar_snapshot.find(agent_key) orelse return false;
    if (handler.client.model.workspace.tabForPane(agent_key.pane_id)) |tab| {
        if (handler.client.model.workspace.activeConst().?.location.tab_id != tab.location.tab_id)
            try handler.selectTab(tab.location.tab_id);
        const active = handler.client.model.workspace.active() orelse return false;
        const shift = active.model.focusPaneShift(agent_key.pane_id);
        if (!shift.focused) return false;
        if (shift.layout_changed) {
            handler.client.graphics_store.invalidatePlacements();
            try handler.client.resizeAttached(&active.model, handler.client.view.workbench());
        }
        try handler.client.syncPaneFocus(&active.model);
        handler.client.view.invalidate();
        handler.redraw = true;
        return false;
    }
    if (handler.client.requests.count != 0) return false;
    const fallback = switch (agent.location.workspace) {
        .workspace => |workspace| workspace,
        .worktree => null,
    };
    try handler.beginWorkspaceHandoff(.{ .pane = agent_key.pane_id }, fallback);
    return true;
}

pub fn forward(handler: *InputHandler, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    switch (handler.client.mode) {
        .prompt => try handler.promptInput(bytes),
        .copy => {},
        .normal => {
            const model = handler.activeModel() orelse return;
            const pane = model.focusedPane() orelse return;
            if (!pane.attached) return;
            try handler.sendPaneBytes(pane, bytes);
        },
    }
}

/// The prompt mode's byte sink. The view edits the text; a cancel inside
/// the editor is reconciled back into the mode here, the one place both
/// are observed together.
fn promptInput(handler: *InputHandler, bytes: []const u8) !void {
    switch (handler.client.view.handleNameInput(bytes)) {
        .editing => {},
        .cancelled => handler.client.mode = .normal,
        .submitted => |name| if (handler.client.view.creatingWorkspace())
            try handler.submitWorkspaceCreate(name)
        else if (handler.client.view.renamedWorkspace() != null)
            try handler.submitWorkspaceRename(name)
        else
            try handler.submitTabRename(name),
    }
    handler.redraw = true;
}

pub fn key(handler: *InputHandler, value: keybind.Key) !void {
    if (handler.client.view.hasAttachmentModal()) {
        if (value.code == .escape) _ = handler.client.view.closeAttachmentModal();
        handler.redraw = true;
        return;
    }
    switch (handler.client.mode) {
        .prompt => {
            var editing_bytes: [32]u8 = undefined;
            try handler.promptInput(try input_mod.encodeKey(&editing_bytes, value, .{}));
        },
        .copy => try handler.copyModeKey(value),
        .normal => {
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
        },
    }
}

fn isClipboardImagePasteKey(value: keybind.Key) bool {
    return value.isCtrl('v') and !value.mods.alt and !value.mods.shift;
}

fn sendPaste(handler: *InputHandler, text: []const u8) !void {
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
    switch (handler.client.mode) {
        .prompt => try handler.promptInput("\x1b[200~"),
        .copy => {},
        .normal => {
            const model = handler.activeModel() orelse return;
            const pane = model.focusedPane() orelse return;
            if (!pane.attached) return;
            handler.client.paste_pane = pane.id;
            if (pane.input_modes.bracketed_paste)
                try handler.sendPaneBytes(pane, "\x1b[200~");
        },
    }
}

pub fn pasteContent(handler: *InputHandler, text: []const u8) !void {
    if (handler.client.view.hasAttachmentModal()) return;
    switch (handler.client.mode) {
        .prompt => try handler.promptInput(text),
        .copy => {},
        .normal => {
            const pane_id = handler.client.paste_pane orelse return;
            const pane = handler.client.model.workspace.findPane(pane_id) orelse return;
            if (pane.attached) try handler.sendPaneBytes(pane, text);
        },
    }
}

pub fn pasteEnd(handler: *InputHandler) !void {
    if (handler.client.view.hasAttachmentModal()) return;
    switch (handler.client.mode) {
        .prompt => try handler.promptInput("\x1b[201~"),
        .copy => {},
        .normal => {
            const pane_id = handler.client.paste_pane orelse return;
            handler.client.paste_pane = null;
            const pane = handler.client.model.workspace.findPane(pane_id) orelse return;
            if (pane.attached and pane.input_modes.bracketed_paste)
                try handler.sendPaneBytes(pane, "\x1b[201~");
        },
    }
}

fn sendPaneBytes(
    handler: *InputHandler,
    pane: *multiplexer.Pane,
    bytes: []const u8,
) !void {
    const started = diagnostics.now(handler.client.io);
    if (!pane.scroll.atBottom(pane.buffer.h)) {
        const bottom = pane.scroll.maxOffset(pane.buffer.h);
        try handler.setViewport(pane, bottom);
    }
    try handler.client.enqueueInput(pane.id, bytes);
    if (comptime diagnostics.enabled) {
        handler.client.metrics.input_events += 1;
        handler.client.metrics.input_bytes += bytes.len;
        handler.client.metrics.input_enqueue.observe(diagnostics.elapsed(started, diagnostics.now(handler.client.io)));
    }
}

fn setViewport(handler: *InputHandler, pane: *multiplexer.Pane, offset: u32) !void {
    const clamped = @min(offset, pane.scroll.maxOffset(pane.buffer.h));
    if (pane.scroll.offset == clamped) return;
    pane.scroll.offset = clamped;
    try handler.client.graphics_store.setPaneVisible(
        pane.id,
        pane.scroll.atBottom(pane.buffer.h),
    );
    if (handler.activeModel()) |model| model.composition_invalidated = true;
    try handler.client.enqueue(.{ .set_pane_viewport = .{
        .pane_id = pane.id,
        .offset = clamped,
    } });
    handler.redraw = true;
}

fn enterCopyMode(handler: *InputHandler) !void {
    if (handler.client.mode != .normal) return;
    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    const cursor: copy_mode.Point = if (pane.cursor.visible)
        .{ .x = pane.cursor.x, .y = pane.scroll.offset + pane.cursor.y }
    else
        .{ .x = 0, .y = pane.scroll.offset + pane.buffer.h -| 1 };
    handler.client.mode = .{ .copy = .init(pane.id, cursor, pane.scroll.offset) };
    model.setPaneCopyView(pane.id, handler.client.mode.copy.view());
    handler.client.view.invalidate();
    handler.redraw = true;
}

fn leaveCopyMode(handler: *InputHandler, copy: bool) !void {
    const state = switch (handler.client.mode) {
        .copy => |value| value,
        else => return,
    };
    const model = handler.activeModel() orelse {
        handler.client.mode = .normal;
        handler.client.view.invalidate();
        handler.redraw = true;
        return;
    };
    const pane = model.find(state.pane_id);
    if (copy and state.anchor != null) {
        const anchor = state.anchor.?;
        try handler.client.enqueue(.{ .copy_selection = .{
            .pane_id = state.pane_id,
            .start_x = anchor.x,
            .start_y = anchor.y,
            .end_x = state.cursor.x,
            .end_y = state.cursor.y,
            .linewise = state.linewise,
        } });
    }
    if (pane) |value| {
        model.setPaneCopyView(value.id, null);
        try handler.setViewport(value, state.entry_offset);
    }
    handler.client.mode = .normal;
    model.composition_invalidated = true;
    handler.client.view.invalidate();
    handler.redraw = true;
}

fn copyModeKey(handler: *InputHandler, pressed: keybind.Key) !void {
    const state = &handler.client.mode.copy;
    const model = handler.activeModel() orelse {
        handler.client.mode = .normal;
        handler.client.view.invalidate();
        handler.redraw = true;
        return;
    };
    const pane = model.find(state.pane_id) orelse {
        handler.client.mode = .normal;
        handler.client.view.invalidate();
        handler.redraw = true;
        return;
    };
    const effect = copy_mode.applyKey(state, pressed, &pane.buffer, pane.scroll);
    if (effect.exit) return handler.leaveCopyMode(effect.copy);
    if (!effect.handled) return;
    model.setPaneCopyView(pane.id, state.view());
    try handler.setViewport(pane, state.viewport_offset);
    handler.redraw = true;
}

pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
    if (comptime diagnostics.enabled) handler.client.metrics.mouse_events += 1;
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
    var interaction = handler.client.view.handleMouse(
        &handler.client.model.workspace,
        model,
        cell_event,
        monotonic(handler.client.io),
    );
    const agent_handoff = if (interaction.focus_agent) |agent_key|
        try handler.focusSidebarAgent(agent_key)
    else
        false;
    if (interaction.select_tab) |tab_id| try handler.selectTab(tab_id);
    if (interaction.rename_tab) |tab_id| {
        if (handler.client.mode == .normal) {
            if (handler.client.model.workspace.find(tab_id)) |tab| {
                handler.client.beginTabRenamePrompt(tab_id, tab.labelSlice());
                handler.redraw = true;
            }
        }
    }
    if (interaction.select_workspace) |workspace| try handler.switchWorkspace(workspace);
    if (interaction.notification_target) |target| switch (target) {
        .none => {},
        .select_tab => |tab_id| try handler.selectTab(tab_id),
        .select_workspace => |workspace| try handler.switchWorkspace(workspace),
        .focus_pane => |pane_id| {
            const shift = model.focusPaneShift(pane_id);
            if (shift.focused) {
                interaction.layout_changed = shift.layout_changed;
                handler.client.view.invalidate();
            }
        },
    };
    if (interaction.notification_target != null)
        try handler.client.scheduleNotificationTick();
    if (handler.client.model.workspace.active()) |active|
        try handler.client.syncPaneFocus(&active.model);
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
        if (handler.client.mode == .copy) {
            const state = &handler.client.mode.copy;
            if (state.pane_id == pane.id) {
                state.vertical(delta, pane.scroll, pane.buffer.h);
                model.setPaneCopyView(pane.id, state.view());
                try handler.setViewport(pane, state.viewport_offset);
                handler.redraw = true;
                return;
            }
        }
        if (!pane.mouse.sgr or !mouseTracked(pane.mouse.tracking, cell_event.kind)) {
            if (pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll and
                pane.scroll.atBottom(pane.buffer.h))
            {
                const bytes = if (delta < 0) "\x1b[A" else "\x1b[B";
                for (0..@abs(delta)) |_| try handler.client.enqueueInput(pane.id, bytes);
            } else {
                const current: i64 = pane.scroll.offset;
                const wanted: u32 = @intCast(@max(0, current + delta));
                try handler.setViewport(pane, wanted);
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
    if (handler.client.mode == .prompt) return .continue_routing;
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
        else => if (handler.client.mode == .copy)
            try handler.leaveCopyMode(false),
    }
    switch (value) {
        .split_pane => |direction| try handler.beginSplit(switch (direction) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        }),
        .focus_pane => |direction| try handler.moveFocus(switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }),
        .resize_pane => |direction| try handler.resizePane(switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }),
        .toggle_pane_fullscreen => try handler.togglePaneFullscreen(),
        .toggle_sidebar => {
            handler.client.view.toggleSidebar();
            handler.client.graphics_store.invalidatePlacements();
            if (handler.activeModel()) |model| {
                try handler.client.resizeAttached(
                    model,
                    handler.client.view.workbench(),
                );
            }
            handler.redraw = true;
        },
        .toggle_workspace_list => {
            handler.client.view.toggleWorkspaceList();
            handler.redraw = true;
        },
        .new_workspace => try handler.beginWorkspaceCreate(),
        .rename_workspace => if (handler.client.model.workspace.workspace) |workspace| {
            handler.client.beginWorkspaceRenamePrompt(
                workspace,
                handler.client.model.workspace.workspaceName(),
            );
            handler.redraw = true;
        },
        .select_workspace => |position| try handler.selectWorkspacePosition(position),
        .close_pane => try handler.closeFocused(),
        .new_tab => try handler.createTab(),
        .select_tab_offset => |offset| try handler.selectTabOffset(offset),
        .select_tab => |position| try handler.selectTabPosition(position),
        .rename_tab => if (handler.client.model.workspace.active()) |tab| {
            handler.client.beginTabRenamePrompt(tab.location.tab_id, tab.labelSlice());
            handler.redraw = true;
        },
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
        .enter_copy_mode => try handler.enterCopyMode(),
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
        .sidebar_visible = handler.client.view.sidebar_requested,
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    };
    const focused = model.focusedPane();
    return .{
        .sidebar_visible = handler.client.view.sidebar_requested,
        .tab_count = @intCast(handler.client.model.workspace.count),
        .active_tab_index = @intCast(handler.client.model.workspace.activeIndex() orelse 0),
        .pane_count = @intCast(model.pane_count),
        .focused_pane_id = if (focused) |pane| schema.id.raw(pane.id) else 0,
    };
}

fn beginSplit(handler: *InputHandler, axis: layout_mod.Axis) !void {
    if (handler.client.requests.has(.pane_operation)) return;
    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    const location = model.location orelse return;
    const prospective = model.prospectiveSplit(
        pane.id,
        axis,
        handler.client.view.workbench(),
    ) orelse
        return;
    const existing_size = rectSize(prospective.existing_content) orelse return;
    const new_size = rectSize(prospective.new_content) orelse return;
    const request_id = try handler.client.nextId();

    try handler.client.enqueue(.{ .pane_resize = .{
        .pane_id = pane.id,
        .size = existing_size,
    } });
    handler.client.enqueueRequest(
        request_id,
        .{ .split = .{
            .target_pane = pane.id,
            .location = location,
            .axis = axis,
        } },
        .{ .create_pane = .{
            .request_id = request_id,
            .location = location,
            .size = new_size,
            .launch = .{
                .cwd = handler.client.options.cwd,
                .cwd_source = pane.id,
                .arguments = handler.client.options.arguments,
            },
        } },
    ) catch |err| {
        try handler.restoreFocusedSize(pane.id);
        return err;
    };
}

fn restoreFocusedSize(handler: *InputHandler, pane_id: schema.PaneId) !void {
    const model = handler.activeModel() orelse return;
    const size = model.contentSize(pane_id, handler.client.view.workbench()) orelse return;
    try handler.client.enqueue(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = size,
    } });
}

fn moveFocus(handler: *InputHandler, direction: layout_mod.Direction) !void {
    const model = handler.activeModel() orelse return;
    if (model.focusDirection(direction, handler.client.view.workbench()) != null) {
        try handler.client.syncPaneFocus(model);
        if (model.layout.isFullscreen()) {
            handler.client.graphics_store.invalidatePlacements();
            try handler.client.resizeAttached(
                model,
                handler.client.view.workbench(),
            );
        }
        handler.client.view.invalidate();
        handler.redraw = true;
    }
}

fn resizePane(handler: *InputHandler, direction: layout_mod.Direction) !void {
    const model = handler.activeModel() orelse return;
    if (!model.resizeFocused(direction, handler.client.view.workbench())) return;
    handler.client.graphics_store.invalidatePlacements();
    try handler.client.resizeAttached(model, handler.client.view.workbench());
    handler.client.view.invalidate();
    handler.redraw = true;
}

fn togglePaneFullscreen(handler: *InputHandler) !void {
    const model = handler.activeModel() orelse return;
    if (!model.toggleFullscreen()) return;
    handler.client.graphics_store.invalidatePlacements();
    try handler.client.resizeAttached(model, handler.client.view.workbench());
    handler.client.view.invalidate();
    handler.redraw = true;
}

fn closeFocused(handler: *InputHandler) !void {
    if (handler.client.requests.has(.pane_operation)) return;
    const tab = handler.client.model.workspace.active() orelse return;
    const pane = tab.model.focusedPane() orelse return;
    if (!pane.attached) return;
    const location = tab.location;
    const request_id = try handler.client.nextId();
    try handler.client.enqueueRequest(
        request_id,
        .{ .close_pane = .{ .pane_id = pane.id, .location = location } },
        .{ .close_pane = .{
            .request_id = request_id,
            .pane_id = pane.id,
        } },
    );
}

fn createTab(handler: *InputHandler) !void {
    if (handler.client.requests.has(.tab_operation)) return;
    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    const workspace = handler.client.model.workspace.workspace orelse return;
    const request_id = try handler.client.nextId();
    try handler.client.enqueueRequest(
        request_id,
        .{ .create_tab = workspace },
        .{ .create_tab = .{
            .request_id = request_id,
            .workspace = workspace,
            .size = rectSize(handler.client.view.workbench()) orelse return,
            .launch = .{
                .cwd = handler.client.options.cwd,
                .cwd_source = pane.id,
                .arguments = handler.client.options.arguments,
            },
        } },
    );
}

fn beginWorkspaceCreate(handler: *InputHandler) !void {
    const client = handler.client;
    if (client.requests.count != 0) return;
    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    client.beginWorkspaceCreatePrompt();
    handler.redraw = true;
}

fn submitWorkspaceCreate(handler: *InputHandler, name: []const u8) !void {
    const client = handler.client;
    if (client.requests.count != 0 or !client.view.creatingWorkspace()) return;
    const model = handler.activeModel() orelse return;
    const pane = model.focusedPane() orelse return;
    if (!pane.attached) return;
    @memcpy(client.workspace_create_name[0..name.len], name);
    client.workspace_create_name_len = @intCast(name.len);
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .create_workspace,
        .{ .create_workspace = .{
            .request_id = request_id,
            .size = rectSize(client.view.workbench()) orelse return,
            .name = client.workspace_create_name[0..client.workspace_create_name_len],
            .launch = .{
                .cwd = client.options.cwd,
                .cwd_source = pane.id,
                .arguments = client.options.arguments,
            },
        } },
    );
    client.finishNamePrompt();
}

fn submitWorkspaceRename(handler: *InputHandler, name: []const u8) !void {
    const client = handler.client;
    if (client.requests.has(.workspace_operation)) return;
    const workspace = client.view.renamedWorkspace() orelse return;
    const request_id = try client.nextId();
    try client.enqueueWorkspaceRenameRequest(.{
        .request_id = request_id,
        .workspace = workspace,
        .name = name,
    });
    client.finishNamePrompt();
}

fn selectTabOffset(handler: *InputHandler, offset: isize) !void {
    if (handler.client.model.workspace.count < 2) return;
    const count: isize = @intCast(handler.client.model.workspace.count);
    const current: isize = @intCast(handler.client.model.workspace.active_index);
    const position: usize = @intCast(@mod(current + offset, count));
    try handler.selectTab(handler.client.model.workspace.items[position].?.location.tab_id);
}

fn selectTabPosition(handler: *InputHandler, position: usize) !void {
    if (position >= handler.client.model.workspace.count) return;
    try handler.selectTab(handler.client.model.workspace.items[position].?.location.tab_id);
}

fn selectWorkspacePosition(handler: *InputHandler, position: usize) !void {
    const workspaces = &handler.client.view.workspace_list;
    const workspace = workspaces.workspaceAtPosition(position) orelse return;
    try handler.switchWorkspace(workspace);
}

fn closeTab(handler: *InputHandler) !void {
    var use_case = tab_attachments.closeRequestHandler(handler.client);

    _ = try use_case.execute();
}

fn moveTab(handler: *InputHandler, direction: schema.TabMoveDirection) !void {
    if (handler.client.requests.has(.tab_operation)) return;
    const location = handler.client.model.activeTabLocation() orelse return;
    const request_id = try handler.client.nextId();
    try handler.client.enqueueRequest(
        request_id,
        .{ .move_tab = location },
        .{ .move_tab = .{
            .request_id = request_id,
            .location = location,
            .direction = direction,
        } },
    );
}

fn submitTabRename(handler: *InputHandler, label: []const u8) !void {
    if (handler.client.requests.has(.tab_operation)) return;
    const tab_id = handler.client.view.renamedTab() orelse return;
    const tab = handler.client.model.workspace.find(tab_id) orelse return;
    const request_id = try handler.client.nextId();
    try handler.client.enqueueRenameRequest(
        .{
            .request_id = request_id,
            .location = tab.location,
            .label = label,
        },
        .{ .rename_tab = tab.location },
    );
    handler.client.finishNamePrompt();
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
