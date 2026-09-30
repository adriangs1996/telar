//! CLI control: runs a command the telar CLI routed to this client and sends
//! its result back through the runtime.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const client_tests = @import("../execution/client_tests.zig");
const config_adoption = @import("../config/config_adoption.zig");
const copy_mode = @import("../input/copy_mode.zig");
const history_palette = @import("../input/history_palette.zig");
const name_prompt = @import("../input/name_prompt.zig");
const link_opening = @import("../links/link_opening.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const pane_split = @import("../panes/pane_split.zig");
const pane_viewport = @import("../panes/pane_viewport.zig");
const plugin_actions = @import("../plugins/plugin_actions.zig");
const sidebar_toggle = @import("../workspace/sidebar_toggle.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const limit_reached = @import("../notifications/limit_reached.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const Client = @import("../execution/Client.zig");

/// Owns a routed response until its asynchronous send completes. Example: `try cli_control.sendRuntimeClientCompletion(client, reply);`
fn sendRuntimeClientCompletion(model: *data.ClientModel, reply: core.ClientCommand) !void {
    try model.to_runtime.pushClientCompletion(reply);
}

/// Preserves command correlation and returns either its result or a named failure.
pub fn completeClientCommand(client: *Client, command: core.ClientCommand) !void {
    var reply = command;
    executeClientCommand(client, &reply) catch |err| {
        reply.status = .failed;
        try reply.setText(@errorName(err));
    };

    try sendRuntimeClientCompletion(&client.model, reply);
}

/// Validates a routed API request, applies it, and records applied versus admitted status.
fn executeClientCommand(client: *Client, reply: *core.ClientCommand) !void {
    if (reply.status != .request) {
        return error.InvalidClientCommand;
    }

    switch (reply.action) {
        .plugin_run => {
            try plugin_actions.runPluginCommand(client, reply);
        },
        .plugin_disable => {
            try plugin_actions.setPluginEnabled(client, reply, false);
        },
        .plugin_enable => {
            try plugin_actions.setPluginEnabled(client, reply, true);
        },
        .plugin_get => {
            try plugin_actions.describePlugin(client, reply);
        },
        .plugin_list => {
            try plugin_actions.listPlugins(client, reply);
        },
        .config_show => {
            try config_adoption.showConfiguration(client, reply);
        },
        .config_reload => {
            try config_adoption.requestConfigReload(client);
            reply.status = .admitted;
        },
        .layout_apply => {
            try applyCommandLayout(client, reply);
        },
        .layout_get => {
            try writeCommandLayout(&client.model, reply);
        },
        .pane_copy => {
            const selection = try core.CopySelection.fromText(@enumFromInt(reply.target_id), reply.text());
            const tab = client.model.tabs.activeSlot() orelse return error.NoActiveTab;
            const pane = client.model.panes.findInConst(client.model.tabs.location[tab].tab_id, selection.pane_id) orelse return error.PaneNotFound;
            if (!pane.attached) {
                return error.TerminalPaneNotAttached;
            }

            try client.model.to_runtime.push(
                .{
                    .copy_selection = selection,
                },
            );
            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_scroll => {
            const delta = std.math.cast(i32, reply.value) orelse return error.InvalidScrollDelta;
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const tab = client.model.tabs.activeSlot() orelse return error.NoActiveTab;
            const pane = client.model.panes.findInConst(client.model.tabs.location[tab].tab_id, pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or copy_mode.copyModeActive(client)) {
                return error.PaneViewportUnavailable;
            }

            _ = try pane_viewport.applyPaneViewport(
                client,
                .{
                    .pane_id = pane_id,
                    .target = .{
                        .relative = delta,
                    },
                },
            );

            reply.status = .applied;
        },
        .pane_fullscreen => {
            try focusCommandPane(client, reply.target_id);
            const changed = try pane_resize.togglePaneFullscreen(
                client,
                .{
                    .area = client.geometry().area,
                },
            ) orelse return error.PaneFullscreenUnavailable;
            reply.value = @intFromBool(changed.fullscreen);
            reply.status = .applied;
        },
        .pane_resize => {
            const direction = std.meta.stringToEnum(data.LayoutDirection, reply.text()) orelse return error.InvalidPaneDirection;
            try focusCommandPane(client, reply.target_id);
            if (try pane_resize.resizePane(
                client,
                .{
                    .direction = direction,
                    .area = client.geometry().area,
                },
            ) == null) {
                return error.PaneResizeUnavailable;
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .pane_focus => {
            try focusCommandPane(client, reply.target_id);
            reply.status = .applied;
        },
        .pane_close => {
            try focusCommandPane(client, reply.target_id);
            if (try pane_closure.requestPaneClose(&client.model) == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(data.LayoutAxis, reply.text()) orelse return error.InvalidSplitAxis;
            try focusCommandPane(client, reply.target_id);
            if (try pane_split.requestPaneSplit(
                client,
                .{
                    .axis = axis,
                    .area = client.geometry().area,
                },
            ) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_create => {
            if (try pane_split.requestPaneSplit(
                client,
                .{
                    .axis = .horizontal,
                    .area = client.geometry().area,
                },
            ) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.status = .admitted;
        },
        .tab_previous => {
            try selectCommandTabOffset(client, reply, -1);
        },
        .tab_next => {
            try selectCommandTabOffset(client, reply, 1);
        },
        .tab_select => {
            const target: core.TabId = @enumFromInt(reply.target_id);
            if (reply.target_id == 0 or client.model.tabLocation(target) == null) {
                return error.TabNotFound;
            }

            if (client.model.activeTabLocation()) |active| {
                if (active.tab_id == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (try tab_selection.selectTab(
                client,
                .{
                    .target = .{
                        .tab_id = target,
                    },
                },
            ) == null) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .tab_create => {
            if (!try tab_creation.requestTabCreation(
                client,
                .{
                    .label = reply.text(),
                },
            )) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .workspace_select => {
            if (reply.target_id == 0) {
                return error.InvalidWorkspaceId;
            }

            const target: core.WorkspaceId = @enumFromInt(reply.target_id);
            if (!data.workspace_list_snapshot.knowsWorkspace(&client.model, target)) {
                return error.WorkspaceNotFound;
            }

            if (client.model.workspace) |location| {
                if (location == .workspace and location.workspace == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (!try workspace_handoff.selectWorkspace(
                client,
                .{
                    .workspace = target,
                },
            )) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .client_clipboard_copy => {
            try client.model.to_host.writeClipboard(client.gpa, reply.text());
            reply.length = 0;
            reply.status = .admitted;
        },
        .client_open_link => {
            const target = try data.LinkTarget.init(reply.text());
            const tab = client.model.tabs.activeSlot();
            const focused = if (tab) |slot| data.tab_layout.focusedPaneConst(&client.model, slot) else null;
            if (!try link_opening.openLink(client, target, if (focused) |pane| pane.id else null)) {
                return error.LinkOpeningUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .notification_dismiss => {
            if (try notifications.dismissNotificationNow(client, @enumFromInt(reply.target_id)) == null) {
                return error.NotificationNotFound;
            }

            reply.status = .applied;
        },
        .client_copy_mode => {
            if (!copy_mode.copyModeActive(client) and !copy_mode.enterCopyMode(client)) {
                return error.CopyModeUnavailable;
            }

            reply.status = .applied;
        },
        .client_open_history => {
            if (!try history_palette.beginHistoryPalette(&client.model)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .admitted;
        },
        .client_open_goto => {
            if (!name_prompt.openNamePrompt(&client.model, .goto_picker)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .applied;
        },
        .workspace_list_collapse => {
            _ = data.workspace_list.setCollapsed(&client.model, true);

            reply.status = .applied;
        },
        .workspace_list_expand => {
            _ = data.workspace_list.setCollapsed(&client.model, false);

            reply.status = .applied;
        },
        .sidebar_resize => {
            const width = std.math.cast(u16, reply.value) orelse return error.InvalidWidth;
            if (width == 0) {
                return error.InvalidWidth;
            }

            _ = try sidebar_toggle.resizeSidebar(
                client,
                .{
                    .exact = width,
                },
            );
            try writeCommandSidebarState(&client.model, reply);
        },
        .sidebar_hide => {
            if (client.model.sidebar_visible) {
                _ = try sidebar_toggle.toggleSidebar(client);
            }

            try writeCommandSidebarState(&client.model, reply);
        },
        .sidebar_show => {
            if (!client.model.sidebar_visible) {
                _ = try sidebar_toggle.toggleSidebar(client);
            }

            try writeCommandSidebarState(&client.model, reply);
        },
        .sidebar_get => {
            try writeCommandSidebarState(&client.model, reply);
        },
    }
}

/// Resolves an explicit API target before any focus-dependent operation.
fn focusCommandPane(client: *Client, target_id: u64) !void {
    if (target_id == 0) {
        return error.InvalidPaneId;
    }

    const pane_id: core.PaneId = @enumFromInt(target_id);
    const tab = client.model.tabs.activeSlot() orelse return error.NoActiveTab;
    _ = client.model.panes.findInConst(client.model.tabs.location[tab].tab_id, pane_id) orelse return error.PaneNotFound;
    if (client.model.tabs.layout[tab].focused() == pane_id) {
        return;
    }

    if (!((try pane_focus.applyPaneFocus(
        client,
        .{
            .target = .{
                .pane_id = pane_id,
            },
            .area = client.geometry().area,
        },
    )) != null)) {
        return error.PaneFocusUnavailable;
    }
}

fn selectCommandTabOffset(client: *Client, reply: *core.ClientCommand, offset: isize) !void {
    if (client.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    if (client.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return error.ClientBusy;
    }

    const change = try tab_selection.selectTab(
        client,
        .{
            .target = .{
                .offset = offset,
            },
        },
    );
    reply.status = if (change == null) .applied else .admitted;
}

fn writeCommandSidebarState(model: *const data.ClientModel, reply: *core.ClientCommand) !void {
    reply.value = model.sidebar_width;
    try reply.setText(if (model.sidebar_visible) "visible" else "hidden");
    reply.status = .applied;
}

/// Encodes the active layout with stable pane identities into the bounded reply.
fn writeCommandLayout(model: *const data.ClientModel, reply: *core.ClientCommand) !void {
    const tab = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const focused = model.tabs.layout[tab].focused() orelse return error.NoFocusedPane;
    var nodes: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    const tabs = [_]core.ClientTabLayout{
        .{
            .location = model.tabs.location[tab],
            .focused_pane = focused,
            .fullscreen = model.tabs.layout[tab].isFullscreen(),
            .workspace_active = true,
            .nodes = model.tabs.layout[tab].clientLayoutNodes(&nodes),
        },
    };

    var buffer: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try core.encodeClientLayoutSnapshot(
        &buffer,
        .{
            .restored = true,
            .sidebar_visible = model.sidebar_visible,
            .sidebar_width = model.sidebar_width,
            .workspace_list_collapsed = model.workspace_list_collapsed,
            .active_tab = model.tabs.location[tab],
            .tabs = &tabs,
        },
    );
    const text = try std.fmt.bufPrint(
        &reply.bytes,
        "{x}",
        .{
            encoded,
        },
    );
    reply.length = @intCast(text.len);
    reply.status = .applied;
}

/// Validates the owned layout token before committing geometry.
fn applyCommandLayout(client: *Client, reply: *core.ClientCommand) !void {
    if (!client.model.request_lifecycle.tracker.isEmpty()) {
        return error.ClientBusy;
    }

    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try std.fmt.hexToBytes(&bytes, reply.text());
    const message = try core.decodeServer(encoded);
    if (message != .client_layout_snapshot) {
        return error.InvalidLayoutToken;
    }

    const snapshot = message.client_layout_snapshot;
    if (!snapshot.restored or snapshot.tab_count != 1 or snapshot.active_tab == null) {
        return error.InvalidLayoutToken;
    }

    var tabs = snapshot.tabs();
    const tab = (try tabs.next()) orelse return error.InvalidLayoutToken;
    if (!std.meta.eql(tab.location, snapshot.active_tab.?)) {
        return error.InvalidLayoutToken;
    }

    var ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var count: usize = 0;
    var nodes = tab.nodes();
    while (try nodes.next()) |node| {
        if (node == .pane) {
            if (count == ids.len) {
                return error.InvalidLayoutToken;
            }

            ids[count] = node.pane.id;
            count += 1;
        }
    }

    try pane_resize.applyPaneLayout(
        client,
        .{
            .location = tab.location,
            .layout = try data.WorkspaceLayout.fromClientLayout(tab),
            .panes = .{
                .ids = ids[0..count],
                .focused = tab.focused_pane,
            },
            .area = client.geometry().area,
        },
    );
    reply.length = 0;
    reply.status = .applied;
}

/// One tab operation waits for the runtime at a time.
const pending_tab_limit = core.Limit.declare("tabs.one_operation_in_flight", "tab operations", 1);

/// Opens a bound command in its own tab. A command asked for while another
/// tab operation waits is lost, unlike a repeated key press, so it is named.
///
/// ```zig
/// try cli_control.createCommandTab(client, &command);
/// ```
pub fn createCommandTab(client: *Client, command: *const data.CommandTab) !void {
    var arguments: [data.CommandTab.max_arguments][]const u8 = undefined;
    for (0..command.argument_count) |index| {
        arguments[index] = command.argument(index);
    }

    const requested = try tab_creation.requestTabCreation(
        client,
        .{
            .label = command.label(),
            .arguments = arguments[0..command.argument_count],
        },
    );
    if (!requested and client.model.request_lifecycle.tracker.has(.tab_operation)) {
        limit_reached.report(
            client,
            .{
                .limit = pending_tab_limit,
            },
        );
    }
}

test "layout export decodes to the same active pane and split tree" {
    try client_tests.layoutRoundTrip(writeCommandLayout);
}
