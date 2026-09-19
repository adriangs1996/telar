const tab_selections = @import("../tabs/tab_selections.zig");
const pane_splits = @import("../panes/pane_splits.zig");
const std = @import("std");
const Axis = @import("../../workspace/layout_support.zig").Axis;
const pane_focus = @import("../panes/pane_focus.zig");
const pane_closures = @import("../panes/pane_closures.zig");
const Direction = @import("../../workspace/layout_support.zig").Direction;
const pane_geometry = @import("../panes/pane_geometry.zig");
const copy_modes = @import("../input/copy_modes.zig");
const pane_viewports = @import("../panes/pane_viewports.zig");
const agent_threads = @import("../agents/agent_threads.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const name_prompts = @import("../input/name_prompts.zig");
const history_palettes = @import("../input/history_palettes.zig");
const notifications = @import("../notifications/notifications.zig");
const LinkTarget = @import("../../links/LinkTarget.zig");
const link_openings = @import("../input/link_openings.zig");
const AgentThreadHandler = @import("../../application/agents/AgentThreadHandler.zig");
const layout_commands = @import("layout_commands.zig");
const config_reloads = @import("../configuration/config_reloads.zig");
const config_queries = @import("../configuration/config_queries.zig");
const plugin_queries = @import("../configuration/plugin_queries.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Executes a semantic command in this client's disposable state. Example: `try client_commands.apply(client, command);`
pub fn apply(client: *Client, command: core.ClientCommand) !void {
    var reply = command;
    execute(client, &reply) catch |err| {
        reply.status = .failed;
        try reply.setText(@errorName(err));
    };
    try runtime_transport.enqueueClientCompletion(client, reply);
}

fn execute(client: *Client, reply: *core.ClientCommand) !void {
    if (reply.status != .request) {
        return error.InvalidClientCommand;
    }

    switch (reply.action) {
        .plugin_list => {
            try plugin_queries.list(client, reply);
        },
        .config_show => {
            try config_queries.show(client, reply);
        },
        .config_reload => {
            try config_reloads.request(client);
            reply.status = .admitted;
        },
        .layout_apply => {
            try layout_commands.apply(client, reply);
        },
        .layout_get => {
            try layout_commands.get(client, reply);
        },
        .pane_copy => {
            const selection = try core.CopySelection.fromText(@enumFromInt(reply.target_id), reply.text());
            const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(selection.pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or pane.kind != .terminal) {
                return error.TerminalPaneNotAttached;
            }

            try runtime_transport.enqueue(client, .{ .copy_selection = selection });
            reply.length = 0;
            reply.status = .admitted;
        },
        .agent_view_collapse => {
            _ = client.model.agentPane(@enumFromInt(reply.target_id)) orelse return error.AgentPaneNotAttached;
            const item_id = std.fmt.parseUnsigned(u64, reply.text(), 10) catch return error.InvalidItemId;
            if (item_id == 0 or (reply.value != 0 and reply.value != 1)) {
                return error.InvalidThreadControl;
            }

            try client.host_input_source.setThreadExpansion(.{ .pane_id = @enumFromInt(reply.target_id), .item_id = item_id, .expanded = false, .work = reply.value == 1 });
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_view_expand => {
            _ = client.model.agentPane(@enumFromInt(reply.target_id)) orelse return error.AgentPaneNotAttached;
            const item_id = std.fmt.parseUnsigned(u64, reply.text(), 10) catch return error.InvalidItemId;
            if (item_id == 0 or (reply.value != 0 and reply.value != 1)) {
                return error.InvalidThreadControl;
            }

            try client.host_input_source.setThreadExpansion(.{ .pane_id = @enumFromInt(reply.target_id), .item_id = item_id, .expanded = true, .work = reply.value == 1 });
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_attach => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            const handler: AgentThreadHandler = .{ .model = &client.model };
            if (!try handler.attachImage(pane_id, reply.text())) {
                return error.DraftAttachmentRejected;
            }

            reply.value = pane.composerImages().count;
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_set => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            if (std.mem.indexOfScalar(u8, reply.text(), 0) != null) {
                return error.InvalidDraftText;
            }

            if (!std.mem.eql(u8, pane.composerSlice(), reply.text())) {
                const handler: AgentThreadHandler = .{ .model = &client.model };
                if (!handler.edit(pane_id, .{ .replace_range = .{ .range = .{ 0, @intCast(pane.composerSlice().len) }, .text = reply.text() } })) {
                    return error.DraftEditRejected;
                }
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_get => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            reply.value = pane.composerImages().count;
            try reply.setText(pane.composerSlice());
            reply.status = .applied;
        },
        .client_clipboard_copy => {
            try client.host_clipboard.set(client.host_clipboard.context, reply.text());
            reply.length = 0;
            reply.status = .admitted;
        },
        .client_open_link => {
            const target = try LinkTarget.init(reply.text());
            if (!try link_openings.apply(client, target)) {
                return error.LinkOpeningUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .notification_dismiss => {
            if (try notifications.dismissNow(client, @enumFromInt(reply.target_id)) == null) {
                return error.NotificationNotFound;
            }

            reply.status = .applied;
        },
        .client_copy_mode => {
            if (!copy_modes.active(client) and !copy_modes.enter(client)) {
                return error.CopyModeUnavailable;
            }

            reply.status = .applied;
        },
        .client_open_history => {
            if (!try history_palettes.begin(client)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .admitted;
        },
        .client_open_goto => {
            if (!name_prompts.beginGotoPicker(client)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .applied;
        },
        .agent_create => {
            if (!client.model.hostCapabilities().agent_panes) {
                return error.AgentPanesUnsupported;
            }

            var handler = tab_creations.requestHandler(client);
            if (!try handler.execute(.{ .kind = .agent, .label = if (reply.length == 0) "Codex" else reply.text() })) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .workspace_list_collapse => {
            if (client.model.setWorkspaceListCollapsed(true) != null) {
                client.chrome.setWorkspaceListCollapsed(true);
            }

            reply.status = .applied;
        },
        .workspace_list_expand => {
            if (client.model.setWorkspaceListCollapsed(false) != null) {
                client.chrome.setWorkspaceListCollapsed(false);
            }

            reply.status = .applied;
        },
        .sidebar_resize => {
            const width = std.math.cast(u16, reply.value) orelse return error.InvalidWidth;
            if (width == 0) {
                return error.InvalidWidth;
            }

            var handler = sidebar_toggles.resizeHandler(client);
            _ = try handler.execute(.{ .exact = width });
            try sidebarState(client, reply);
        },
        .sidebar_hide => {
            if (client.model.sidebarVisible()) {
                var handler = sidebar_toggles.handler(client);
                _ = try handler.execute();
            }

            try sidebarState(client, reply);
        },
        .sidebar_show => {
            if (!client.model.sidebarVisible()) {
                var handler = sidebar_toggles.handler(client);
                _ = try handler.execute();
            }

            try sidebarState(client, reply);
        },
        .sidebar_get => {
            try sidebarState(client, reply);
        },
        .pane_scroll => {
            const delta = std.math.cast(i32, reply.value) orelse return error.InvalidScrollDelta;
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or copy_modes.active(client)) {
                return error.PaneViewportUnavailable;
            }

            if (pane.kind == .agent) {
                try agent_threads.scroll(client, pane_id, @floatFromInt(delta));
            } else {
                var handler = pane_viewports.handler(client);
                _ = try handler.execute(.{ .pane_id = pane_id, .target = .{ .relative = delta } });
            }

            reply.status = .applied;
        },
        .pane_fullscreen => {
            try focusPane(client, reply.target_id);
            var handler = pane_geometry.fullscreenHandler(client);
            const changed = try handler.execute(.{ .area = client.geometry().area }) orelse return error.PaneFullscreenUnavailable;
            reply.value = @intFromBool(changed.fullscreen);
            reply.status = .applied;
        },
        .pane_resize => {
            const direction = std.meta.stringToEnum(Direction, reply.text()) orelse return error.InvalidPaneDirection;
            try focusPane(client, reply.target_id);
            var handler = pane_geometry.resizeHandler(client);
            if (try handler.execute(.{ .direction = direction, .area = client.geometry().area }) == null) {
                return error.PaneResizeUnavailable;
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .pane_focus => {
            try focusPane(client, reply.target_id);
            reply.status = .applied;
        },
        .pane_close => {
            try focusPane(client, reply.target_id);
            var handler = pane_closures.requestHandler(client);
            if (try handler.execute() == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(Axis, reply.text()) orelse return error.InvalidSplitAxis;
            try focusPane(client, reply.target_id);
            var handler = pane_splits.requestHandler(client);
            if (try handler.execute(.{ .axis = axis, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_create => {
            var handler = pane_splits.requestHandler(client);
            if (try handler.execute(.{ .axis = .horizontal, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.status = .admitted;
        },
        .tab_previous => {
            try selectTabOffset(client, reply, -1);
        },
        .tab_next => {
            try selectTabOffset(client, reply, 1);
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

            var handler = tab_selections.selectionHandler(client);
            if (try handler.execute(.{ .target = .{ .tab_id = target } }) == null) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .tab_create => {
            var handler = tab_creations.requestHandler(client);
            if (!try handler.execute(.{ .label = reply.text() })) {
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
            if (!client.model.knowsWorkspace(target)) {
                return error.WorkspaceNotFound;
            }

            if (client.model.workspaceLocation()) |location| {
                if (location == .workspace and location.workspace == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (!try workspace_handoffs.selectWorkspace(client, .{ .workspace = target })) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
    }
}

fn selectTabOffset(client: *Client, reply: *core.ClientCommand, offset: isize) !void {
    if (client.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    var handler = tab_selections.selectionHandler(client);
    if (handler.snapshots.pending(handler.snapshots.context)) {
        return error.ClientBusy;
    }

    const change = try handler.execute(.{ .target = .{ .offset = offset } });
    reply.status = if (change == null) .applied else .admitted;
}

fn focusPane(client: *Client, target_id: u64) !void {
    if (target_id == 0) {
        return error.InvalidPaneId;
    }

    const pane_id: core.PaneId = @enumFromInt(target_id);
    const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
    _ = tab.findConst(pane_id) orelse return error.PaneNotFound;
    if (tab.layout.focused() == pane_id) {
        return;
    }

    var handler = pane_focus.handler(client);
    if (try handler.execute(.{ .target = .{ .pane_id = pane_id }, .area = client.geometry().area }) == null) {
        return error.PaneFocusUnavailable;
    }
}

fn sidebarState(client: *const Client, reply: *core.ClientCommand) !void {
    reply.value = client.model.sidebarWidth();
    try reply.setText(if (client.model.sidebarVisible()) "visible" else "hidden");
    reply.status = .applied;
}
