//! Actions: runs one bound action, from a key binding or from a validated Lua
//! effect, against the focused pane or the client.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const agent_control = @import("../agents/agent_control.zig");
const cli_control = @import("../connection/cli_control.zig");
const copy_mode = @import("copy_mode.zig");
const history_palette = @import("history_palette.zig");
const key_routing = @import("key_routing.zig");
const lua_action = @import("lua_action.zig");
const name_prompt = @import("name_prompt.zig");
const suggest_command = @import("suggest_command.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const pane_split = @import("../panes/pane_split.zig");
const pane_viewport = @import("../panes/pane_viewport.zig");
const plugin_actions = @import("../plugins/plugin_actions.zig");
const client_layout = @import("../workspace/client_layout.zig");
const sidebar_toggle = @import("../workspace/sidebar_toggle.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const tab_move = @import("../workspace/tab_move.zig");
const tab_removal = @import("../workspace/tab_removal.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_creation = @import("../workspace/workspace_creation.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const Client = @import("../AttachedClient.zig");

const ctrl_h = data.chord.parseKey("ctrl+h") catch unreachable;

const ctrl_j = data.chord.parseKey("ctrl+j") catch unreachable;

const ctrl_k = data.chord.parseKey("ctrl+k") catch unreachable;

const ctrl_l = data.chord.parseKey("ctrl+l") catch unreachable;

/// Bindings obey prompt authority; validated native effects retain their caller's authority.
const ActionOrigin = enum { binding, effect };

/// Executes a binding or a validated native effect with its existing prompt policy.
/// Example: `_ = try actions.executeAction(client, .{ .split_pane = .horizontal }, .binding);`
pub fn executeAction(client: *Client, value: data.Action, origin: ActionOrigin) anyerror!data.KeybindControl {
    if (origin == .binding and client.model.name_prompt.active()) {
        return .continue_routing;
    }

    switch (value) {
        .lua_callback, .lua_expr => {
            std.debug.assert(origin == .binding);
            return lua_action.executeLuaAction(client, switch (value) {
                .lua_callback => |reference| .{
                    .callback = reference,
                },
                .lua_expr => |reference| .{
                    .expression = reference,
                },
                else => unreachable,
            });
        },
        .plugin => |requested| {
            std.debug.assert(origin == .binding);
            _ = try plugin_actions.startPluginAction(client, requested, client.model.callbackContext());
            return .continue_routing;
        },
        else => {},
    }

    if (value != .enter_copy_mode and copy_mode.copyModeActive(client)) {
        _ = try copy_mode.leaveCopyMode(client);
    }

    switch (value) {
        .toggle_thread_view => {
            _ = client.model.togglePaneSurface();
        },
        .scroll_pane => |direction| try pane_viewport.scrollPane(client, direction),
        .split_pane => |direction| _ = try pane_split.requestPaneSplit(
            client,
            .{
                .axis = switch (direction) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .area = client.geometry().area,
            },
        ),
        .focus_pane => |direction| _ = try pane_focus.applyPaneFocus(
            client,
            .{
                .target = .{
                    .direction = switch (direction) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    },
                },
                .area = client.geometry().area,
            },
        ),
        .navigate_pane => |direction| try pane_focus.navigatePane(client, direction),
        .resize_pane => |direction| _ = try pane_resize.resizePane(
            client,
            .{
                .direction = switch (direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                },
                .area = client.geometry().area,
            },
        ),
        .toggle_pane_fullscreen => _ = try pane_resize.togglePaneFullscreen(
            client,
            .{
                .area = client.geometry().area,
            },
        ),
        .toggle_sidebar => _ = try sidebar_toggle.toggleSidebar(client),
        .resize_sidebar => |direction| _ = try sidebar_toggle.resizeSidebar(
            client,
            .{
                .direction = switch (direction) {
                    .left => .narrower,
                    .right => .wider,
                },
            },
        ),
        .toggle_workspace_list => _ = client.model.toggleWorkspaceList(),
        .new_workspace => _ = workspace_creation.beginWorkspacePrompt(client),
        .rename_workspace => _ = name_prompt.openNamePrompt(&client.model, .rename_workspace),
        .select_workspace => |position| _ = try workspace_handoff.selectWorkspace(
            client,
            .{
                .position = position,
            },
        ),
        .close_pane => _ = try pane_closure.requestPaneClose(&client.model),
        .new_tab => _ = try tab_creation.requestTabCreation(
            client,
            .{},
        ),
        .new_agent_tab => try agent_control.createAgentTab(client),
        .select_tab_offset => |offset| _ = try tab_selection.selectTab(
            client,
            .{
                .target = .{
                    .offset = offset,
                },
            },
        ),
        .select_tab => |position| _ = try tab_selection.selectTab(
            client,
            .{
                .target = .{
                    .position = position,
                },
            },
        ),
        .rename_tab => _ = name_prompt.openNamePrompt(&client.model, .rename_active_tab),
        .close_tab => _ = try tab_removal.requestTabClose(client),
        .move_tab => |direction| _ = try tab_move.requestTabMove(
            &client.model,
            .{
                .direction = switch (direction) {
                    .previous => .previous,
                    .next => .next,
                },
            },
        ),
        .detach => {
            try client_layout.synchronizeClientLayout(&client.model);
            try tab_removal.detachAllTabs(client);

            return .stop;
        },
        .enter_copy_mode => _ = copy_mode.enterCopyMode(client),
        .command_tab => |*command| try cli_control.createCommandTab(client, command),
        .goto_picker => _ = name_prompt.openNamePrompt(&client.model, .goto_picker),
        .history_palette => _ = try history_palette.beginHistoryPalette(&client.model),
        .suggest_command => _ = try suggest_command.beginSuggestion(&client.model),
        .notification => |*notification| _ = try notifications.requestNotificationDelivery(&client.model, notification),
        .lua_callback, .lua_expr, .plugin => unreachable,
    }

    return .continue_routing;
}

/// An exclusive owner or unavailable pane prevents held-action repetition.
/// Re-read after executing an action because it may change focus or modes.
/// Example: `const policy = repeatPolicy(action, actions.repeatPane(client));`
pub fn repeatPane(client: *const Client) ?core.PaneId {
    const authority = key_routing.keyRoutingAuthority(client);
    if (data.key_routing.captures(authority) or authority.copy_mode_active) {
        return null;
    }

    const model = client.model.tabs.activeSlot() orelse return null;
    const pane = data.tab_layout.focusedPaneConst(&client.model, model) orelse return null;
    return if (pane.attached) pane.id else null;
}

pub fn navigationKey(direction: data.InputDirection) data.Key {
    return switch (direction) {
        .left => ctrl_h,
        .right => ctrl_l,
        .up => ctrl_k,
        .down => ctrl_j,
    };
}
